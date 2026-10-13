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
# that matched it, as a yes/no (`noul`) question apiece.
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
#   RULEKIT_JUDGE_TIMEOUT  read timeout in seconds (default 10.0)
class JudgeClient
  DEFAULT_URL = 'https://api.typesafe.ai/v1'.freeze
  DEFAULT_MODEL = 'jev-latest'.freeze
  DEFAULT_THRESHOLD = 0.7
  OPEN_TIMEOUT = 3.0
  DOWN_TTL = 60
  # Largest per-file state sent. Beyond this the added lines are cut.
  MAX_CHARS = 8000

  def self.from_env(session_dir:)
    new(
      url: env('RULEKIT_JUDGE_URL', 'TYPESAFE_AI_BASE_URL'),
      model: env('RULEKIT_JUDGE_MODEL') || DEFAULT_MODEL,
      read_timeout: Float(env('RULEKIT_JUDGE_TIMEOUT') || '10.0'),
      api_key: env('RULEKIT_JUDGE_API_KEY', 'TYPESAFE_AI_API_KEY'),
      down_marker: File.join(session_dir, 'judge-down'),
    )
  end

  # The first of `names` set to something non-empty.
  def self.env(*names)
    names.map { |name| ENV[name].to_s }.find { |value| !value.empty? }
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

  # `configs` maps a rule name to its `judge:` hash. Returns the names of the
  # rules that fire for this file — empty when none do or the judge could not
  # answer.
  def fired(configs, relative_path:, new_content:)
    return [] unless configured?

    questions = configs.transform_values { |config| config['question'].to_s }.reject { |_, question| question.empty? }
    return [] if questions.empty?

    answers = probabilities(questions, "File: #{relative_path}\n\n#{new_content}") || {}
    answers.filter_map do |name, probability|
      name if probability >= Float(configs[name].fetch('threshold', DEFAULT_THRESHOLD))
    end
  end

  private

  # `questions` maps a key to the question text. Returns { key => probability }
  # (0..1 that the answer is yes) for every question the judge answered, or nil on
  # any failure.
  def probabilities(questions, text)
    return nil if down?

    body = {
      model: @model,
      state: text[0, MAX_CHARS],
      questions: questions.transform_values { |question| { type: 'noul', instructions: question } },
    }
    response = post(body)
    return mark_down unless response.is_a?(Net::HTTPSuccess)

    answers = JSON.parse(response.body)['answers']
    return nil unless answers.is_a?(Hash)

    questions.each_key.with_object({}) do |key, found|
      value = answers.dig(key, 'noul')
      found[key] = value.to_f if value.is_a?(Numeric)
    end
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
