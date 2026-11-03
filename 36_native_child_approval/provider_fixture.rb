# frozen_string_literal: true

require "webmock"
require_relative "../spec/support/chat_stub"

module NativeChild
  def self.fixed_provider
    WebMock.enable!
    WebMock.disable_net_connect!
    RubyLLM.configure do |config|
      config.openai_protocol = :chat_completions
      config.openai_api_base = "https://example.test/v1"
      config.openai_api_key = "offline"
    end
    ExampleChatStub.new do |body, _|
      messages = body.fetch("messages")
      user_index = messages.rindex { |message| message.fetch("role") == "user" }
      turn = messages.drop(user_index)
      last = turn.last
      parent = body.fetch("tools").any? { |tool| tool.fetch("function").fetch("name") == "dispatch_to_worker" }
      if parent && last.fetch("role") == "tool"
        last.fetch("content").empty? ? "no child output" : "received: #{last.fetch("content")}"
      elsif parent
        ExampleChatStub.tool("dispatch_to_worker", {input: turn.first.fetch("content")})
      elsif last.fetch("role") == "tool"
        if turn.first.fetch("content") == "apply then publish" && last.fetch("content") == "applied"
          ExampleChatStub.tool("publish_request")
        else
          "child finished"
        end
      elsif last.fetch("content") == "independent follow-up"
        "other job finished"
      else
        ExampleChatStub.tool("apply_request")
      end
    end
  end
end
