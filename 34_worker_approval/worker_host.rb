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
  messages = messages.drop(messages.rindex { |message| message["role"] == "user" } || 0)
  if messages.any? { |m| m["role"] == "tool" }
    "approved"
  elsif messages.any? { |m| m["content"] == "apply" }
    ExampleChatStub.tool("apply_request")
  else
    "other job finished"
  end
end

module WorkerApproval
  def self.serve(inbox, handler)
    $stdout.sync = true
    while (command = $stdin.gets&.chomp)
      break unless %w[run run-and-crash-before-reply].include?(command)
      job = inbox.claim
      unless job
        puts JSON.generate(idle: true)
        next
      end
      puts JSON.generate(request: job.fetch("request_id"), token: job.fetch("owner"), pid: Process.pid)
      value = handler.call(job)
      # Test fault at handler return, after persistence and before the supervisor sees the result.
      Process.kill("KILL", Process.pid) if command == "run-and-crash-before-reply"
      puts JSON.generate(value)
      break unless $stdin.gets&.chomp == "ack"
      inbox.finish(job, value)
      puts JSON.generate(ack: true)
    end
  end
end
