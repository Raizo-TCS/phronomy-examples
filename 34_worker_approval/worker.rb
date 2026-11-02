# frozen_string_literal: true

require "webmock"
require_relative "handler"
require_relative "inbox"
require_relative "../spec/support/chat_stub"

# Replace only provider HTTP responses. Agent, Tool, DB and OS processes are real.
WebMock.enable!
WebMock.disable_net_connect!
RubyLLM.configure do |config|
  config.openai_protocol = :chat_completions
  config.openai_api_base = "https://example.test/v1"
  config.openai_api_key = "offline"
end
ExampleChatStub.new do |body, _index|
  messages = body.fetch("messages")
  if messages.any? { |m| m["role"] == "tool" }
    "approved"
  elsif messages.any? { |m| m["content"] == "apply" }
    ExampleChatStub.tool("apply_request")
  else
    "other job finished"
  end
end

$stdout.sync = true
inbox = Inbox.new(ARGV.fetch(0))
handler = WorkerApproval::Handler.new(WorkerApproval.store(ARGV.fetch(0)))
while $stdin.gets&.chomp == "run"
  job = inbox.claim
  unless job
    puts JSON.generate(idle: true)
    next
  end
  puts JSON.generate(request: job.fetch("request_id"), token: job.fetch("owner"), pid: Process.pid)
  value = handler.call(job)
  # The supervisor can kill this process at the precise pre-ACK boundary.
  puts JSON.generate(value)
  break unless $stdin.gets&.chomp == "ack"
  inbox.finish(job, value)
  puts JSON.generate(ack: true)
end
