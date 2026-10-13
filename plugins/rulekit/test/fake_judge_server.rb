#!/usr/bin/env ruby
# Minimal stand-in for a judge backend (TypeSafe's Jev API) so test/judge.sh
# runs without a key.
# Answers POST /v1/systemone with noul 0.9 for every question when the state
# mentions "backfill", 0.1 otherwise, and appends one line per request to $2
# (the request log): the Authorization header, if any, then the body.
#
#   fake_judge_server.rb <port> <request-log>

require 'json'
require 'socket'

port = Integer(ARGV.fetch(0))
log = ARGV.fetch(1)
server = TCPServer.new('127.0.0.1', port)

loop do
  client = server.accept
  request_line = client.gets.to_s
  headers = {}
  while (line = client.gets) && line != "\r\n"
    key, value = line.split(':', 2)
    headers[key.downcase] = value.strip
  end
  body = client.read(headers['content-length'].to_i)
  File.write(log, "#{headers['authorization']} #{body}".strip + "\n", mode: 'a')

  payload = if request_line.start_with?('POST /v1/systemone')
              request = JSON.parse(body)
              noul = request['state'].to_s.downcase.include?('backfill') ? 0.9 : 0.1
              JSON.generate(answers: request['questions'].to_h { |key, _| [key, { 'type' => 'noul', 'noul' => noul }] })
            else
              JSON.generate(status: 'ok')
            end
  client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
  client.close
end
