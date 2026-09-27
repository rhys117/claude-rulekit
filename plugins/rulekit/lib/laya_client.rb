require 'fileutils'
require 'json'
require 'net/http'
require 'uri'

# Optional semantic matching via a local Laya server (https://github.com/NandhaKishorM/laya).
#
# A write rule with a `laya:` block asks Laya a yes/no question about the new
# content and fires when the probability clears the rule's threshold:
#
#   laya:
#     question: "Does this migration backfill data in the same file that adds a NOT NULL column?"
#     threshold: 0.8        # optional, default 0.7
#
# Laya is strictly optional. Every failure — server not running, timeout, bad
# response — returns nil, and the runner treats nil as "rule does not fire".
# After one failed call the server is marked down for this session for
# DOWN_TTL seconds, so a missing server costs one connect attempt, not one per
# tool call; starting the server mid-session is picked up once the TTL lapses.
#
# Env:
#   LAYA_URL      base URL (default http://127.0.0.1:8000)
#   LAYA_TIMEOUT  read timeout in seconds (default 2.0)
#   LAYA_API_KEY  bearer token, if the server was started with one
class LayaClient
  DEFAULT_URL = 'http://127.0.0.1:8000'.freeze
  DEFAULT_THRESHOLD = 0.7
  OPEN_TIMEOUT = 0.2
  DOWN_TTL = 60
  # Laya's English checkpoint reads 512 tokens; send roughly that much.
  MAX_CHARS = 2000
  QUESTION_KEY = 'rule'.freeze

  def self.from_env(session_dir:)
    new(
      url: ENV.fetch('LAYA_URL', DEFAULT_URL),
      read_timeout: Float(ENV.fetch('LAYA_TIMEOUT', '2.0')),
      api_key: ENV['LAYA_API_KEY'],
      down_marker: File.join(session_dir, 'laya-down'),
    )
  end

  def initialize(url:, read_timeout:, api_key:, down_marker:)
    @uri = URI.join(url, '/v1/systemone')
    @read_timeout = read_timeout
    @api_key = api_key
    @down_marker = down_marker
  end

  # Returns true/false for whether the rule fires, or nil when Laya could not
  # answer. `config` is the rule's `laya:` hash.
  def fires?(config, relative_path:, new_content:)
    question = config['question'].to_s
    return nil if question.empty?

    probability = probability(question, "File: #{relative_path}\n\n#{new_content}")
    return nil if probability.nil?

    probability >= Float(config.fetch('threshold', DEFAULT_THRESHOLD))
  end

  # Probability (0..1) that the answer to `question` about `text` is yes, or
  # nil on any failure.
  def probability(question, text)
    return nil if down?

    body = {
      state: text[0, MAX_CHARS],
      questions: { QUESTION_KEY => { type: 'noul', instructions: question } },
    }
    response = post(body)
    return mark_down unless response.is_a?(Net::HTTPSuccess)

    value = JSON.parse(response.body).dig('answers', QUESTION_KEY, 'noul')
    value.is_a?(Numeric) ? value.to_f : nil
  rescue StandardError
    mark_down
  end

  private

  def post(body)
    request = Net::HTTP::Post.new(@uri, 'Content-Type' => 'application/json')
    request['Authorization'] = "Bearer #{@api_key}" if @api_key && !@api_key.empty?
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
