require 'json'
require 'socket'

# Stand-in for a judge backend (TypeSafe's Jev API), so the suite runs without
# a key. Answers POST /v1/systemone and keeps what it was sent. Every question
# gets the same probability of a violation: 0.9 when the state mentions
# "backfill", 0.6 when it mentions "borderline", 0.1 otherwise. A choice
# question puts that weight on its first option and a score question on its
# last level, so a spec marks those as the violating ones.
class FakeJudge
  Request = Struct.new(:authorization, :body) do
    def state
      body['state'].to_s
    end

    def questions
      body['questions'] || {}
    end
  end

  attr_reader :requests

  def initialize
    @requests = []
    @server = TCPServer.new('127.0.0.1', 0)
    @port = @server.addr[1]
    @thread = Thread.new { serve }
  end

  def url
    "http://127.0.0.1:#{@port}/v1"
  end

  def stop
    @thread.kill
    @server.close unless @server.closed?
  end

  private

  def serve
    loop { answer(@server.accept) }
  rescue IOError
    nil
  end

  def answer(client)
    request_line = client.gets.to_s
    headers = {}
    while (line = client.gets) && line != "\r\n"
      key, value = line.split(':', 2)
      headers[key.downcase] = value.strip
    end
    body = JSON.parse(client.read(headers['content-length'].to_i))
    @requests << Request.new(headers['authorization'], body) if request_line.start_with?('POST /v1/systemone')

    state = body['state'].to_s.downcase
    weight = if state.include?('backfill') then 0.9
             elsif state.include?('borderline') then 0.6
             else 0.1
             end
    payload = JSON.generate(answers: body['questions'].transform_values { |question| reply(question, weight) })
    client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{payload.bytesize}\r\n" \
                 "Connection: close\r\n\r\n#{payload}")
  ensure
    client.close
  end

  def reply(question, weight)
    rest = (1 - weight).round(2)

    case question['type']
    when 'choice'
      first, second = question['criteria'].keys
      { 'type' => 'choice', 'choice' => weight > rest ? first : second,
        'probabilities' => { first => weight, second => rest } }
    when 'score'
      last = question['criteria'].size - 1
      { 'type' => 'score', 'score' => (weight * last).round(2),
        'probabilities' => { '0' => rest, last.to_s => weight } }
    else
      { 'type' => 'noul', 'noul' => weight }
    end
  end
end
