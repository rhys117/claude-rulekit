require 'fileutils'
require 'json'
require 'net/http'
require 'uri'

# Optional semantic matching by a hosted or local decision model: "the judge".
#
# A write rule with a `judge:` block asks the judge a yes/no question about
# what the turn changed and fires when the probability clears the rule's
# threshold:
#
#   judge:
#     question: "Does this migration backfill data in the same file that adds a NOT NULL column?"
#     threshold: 0.8        # optional, default 0.7
#     flag: 0.5             # optional: from here up to the threshold, a note to the user
#     criteria:             # optional: what a yes and a no look like
#       true: "add_column null: false, then update_all"
#       false: "add_column alone"
#
# Two more shapes ask for more than yes or no. The probability the rule is
# measured by is then the weight the judge put on the answers that break it:
#
#   judge:                              judge:
#     type: choice                        type: score
#     question: "Where does it log?"      question: "How much does this restate the code?"
#     criteria:                           criteria:          # best first, at most 10
#       logger: "Rails.logger"              - "not at all"
#       stdout: "puts or print"             - "in passing"
#       none: "nothing is logged"           - "line for line"
#     violating: [stdout]                 violating_from: 2  # index of the first level that breaks it
#
# The rule names no model. Which one answers is configuration, so swapping the
# backend never touches write.yml. The default is TypeSafe's hosted Jev
# (https://typesafe.ai); any server that speaks the same `POST .../systemone`
# protocol — a local Laya server, say — works by pointing RULEKIT_JUDGE_URL at
# it. A backend with a different protocol belongs behind this class.
#
# The judge may be a paid network call, so `judge:` rules are not asked about
# on every edit. stop-rules-check.rb evaluates them when the agent finishes a
# turn, and each changed file costs one request carrying every `judge:` rule
# that matched it, as one question apiece (`noul` is the protocol's yes/no).
#
# The judge is strictly optional and fails open. Unconfigured — no API key and
# no URL — nothing is sent at all. Every failure — unreachable, timeout,
# non-2xx, bad JSON — leaves `judge:` rules silent, and marks the judge down
# for this session for DOWN_TTL seconds, so an outage costs one attempt, not
# one per changed file.
#
# Env:
#   RULEKIT_JUDGE_API_KEY  bearer token. Falls back to TYPESAFE_AI_API_KEY.
#   RULEKIT_JUDGE_URL      API base (default https://api.typesafe.ai/v1).
#                          Falls back to TYPESAFE_AI_BASE_URL.
#   RULEKIT_JUDGE_MODEL    model id (default jev-latest)
#   RULEKIT_JUDGE_TIMEOUT  read timeout in seconds (default 10.0). A value
#                          that is not a positive number falls back to it.
class JudgeClient
  DEFAULT_URL = 'https://api.typesafe.ai/v1'.freeze
  DEFAULT_MODEL = 'jev-latest'.freeze
  DEFAULT_THRESHOLD = 0.7
  DEFAULT_TIMEOUT = 10.0
  OPEN_TIMEOUT = 3.0
  DOWN_TTL = 60
  # Largest per-file state sent. Beyond this the added lines are cut.
  MAX_CHARS = 8000

  def self.from_env(session_dir:)
    new(
      url: env('RULEKIT_JUDGE_URL', 'TYPESAFE_AI_BASE_URL'),
      model: env('RULEKIT_JUDGE_MODEL') || DEFAULT_MODEL,
      read_timeout: timeout(env('RULEKIT_JUDGE_TIMEOUT')),
      api_key: env('RULEKIT_JUDGE_API_KEY', 'TYPESAFE_AI_API_KEY'),
      down_marker: File.join(session_dir, 'judge-down'),
    )
  end

  # The first of `names` set to something non-empty.
  def self.env(*names)
    names.map { |name| ENV[name].to_s }.find { |value| !value.empty? }
  end

  def self.timeout(value)
    seconds = Float(value, exception: false)
    seconds&.positive? ? seconds : DEFAULT_TIMEOUT
  end

  def initialize(url:, model:, read_timeout:, api_key:, down_marker:)
    @configured = !(url.nil? && api_key.nil?)
    @uri = URI("#{(url || DEFAULT_URL).chomp('/')}/systemone")
    @model = model
    @read_timeout = read_timeout
    @api_key = api_key
    @down_marker = down_marker
  end

  # A key is enough for the default backend; a URL alone is enough for a local
  # one that asks for no key.
  def configured?
    @configured
  end

  # `configs` maps a rule name to its `judge:` hash. Returns
  # { name => probability } (0..1 that the rule is broken in this file) for
  # every rule the judge answered — empty when it could not.
  def verdicts(configs, relative_path:, new_content:)
    return {} unless configured?

    questions = configs.transform_values { |config| self.class.question(config) }.compact
    return {} if questions.empty?

    answers = ask(questions, "File: #{relative_path}\n\n#{new_content}") || {}
    questions.each_key.with_object({}) do |name, found|
      probability = self.class.violation(configs[name], answers[name])
      found[name] = probability unless probability.nil?
    end
  end

  # The question as the protocol wants it, or nil when the `judge:` hash does
  # not make one: no text, or a choice or score without its answers.
  def self.question(config)
    instructions = config['question'].to_s
    criteria = config['criteria']
    return nil if instructions.empty?

    case config['type'].to_s
    when 'choice'
      return nil unless criteria.is_a?(Hash) && criteria.size >= 2 && !Array(config['violating']).empty?

      { type: 'choice', instructions: instructions, criteria: criteria }
    when 'score'
      return nil unless criteria.is_a?(Array) && criteria.size >= 2 && config['violating_from'].is_a?(Integer)

      { type: 'score', instructions: instructions, criteria: criteria }
    else
      { type: 'noul', instructions: instructions }.merge(criteria.is_a?(Hash) ? { criteria: criteria } : {})
    end
  end

  # Probability the rule is broken, from the judge's answer to its question.
  # nil when the answer is missing or is not the shape that was asked for.
  def self.violation(config, answer)
    return nil unless answer.is_a?(Hash)

    case config['type'].to_s
    when 'choice'
      violating = Array(config['violating']).map(&:to_s)
      weigh(answer, answer['choice']) { |option| violating.include?(option.to_s) }
    when 'score'
      weigh(answer, answer['score']) { |level| Float(level, exception: false).to_f.round >= config['violating_from'] }
    else
      answer['noul'].to_f.clamp(0.0, 1.0) if answer['noul'].is_a?(Numeric)
    end
  end

  # The weight on the answers the block calls violating. Without a
  # distribution, the one answer that was picked decides it outright.
  def self.weigh(answer, picked, &violating)
    return nil if picked.nil?

    weights = answer['probabilities']
    return (violating.call(picked) ? 1.0 : 0.0) unless weights.is_a?(Hash)

    weights.sum { |option, weight| weight.is_a?(Numeric) && violating.call(option) ? weight : 0.0 }.clamp(0.0, 1.0)
  end

  private

  # `questions` maps a key to its question. Returns { key => answer } as the
  # judge gave them, or nil on any failure.
  def ask(questions, text)
    return nil if down?

    response = post(model: @model, state: text[0, MAX_CHARS], questions: questions)
    return mark_down unless response.is_a?(Net::HTTPSuccess)

    answers = JSON.parse(response.body)['answers']
    answers.is_a?(Hash) ? answers : nil
  rescue StandardError
    mark_down
  end

  def post(body)
    request = Net::HTTP::Post.new(@uri, 'Content-Type' => 'application/json')
    request['Authorization'] = "Bearer #{@api_key}" if @api_key
    request.body = JSON.generate(body)

    Net::HTTP.start(@uri.host, @uri.port, use_ssl: @uri.scheme == 'https',
                                          open_timeout: OPEN_TIMEOUT, read_timeout: @read_timeout) do |http|
      http.request(request)
    end
  end

  def down?
    File.exist?(@down_marker) && Time.now - File.mtime(@down_marker) < DOWN_TTL
  end

  def mark_down
    FileUtils.mkdir_p(File.dirname(@down_marker))
    FileUtils.touch(@down_marker)
    nil
  end
end
