require 'json'
require 'socket'

# Stand-in for a judge backend (TypeSafe's Jev API), so the suite runs without
# a key. Answers POST /v1/systemone with noul 0.9 for every question when the
# state mentions "backfill" and 0.1 otherwise, and keeps what it was sent.
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

    noul = body['state'].to_s.downcase.include?('backfill') ? 0.9 : 0.1
    payload = JSON.generate(answers: body['questions'].to_h { |key, _| [key, { 'type' => 'noul', 'noul' => noul }] })
    client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{payload.bytesize}\r\n" \
                 "Connection: close\r\n\r\n#{payload}")
  ensure
    client.close
  end
end
