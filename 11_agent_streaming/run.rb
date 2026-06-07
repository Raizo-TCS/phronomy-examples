#!/usr/bin/env ruby
# frozen_string_literal: true

# 11 Agent Streaming
#
# Demonstrates token-level streaming from Agent::Base#stream.
# Tokens are printed in real-time as the LLM generates them.
# StreamEvent types: :token, :tool_call, :tool_result, :done, :error

require_relative "../shared/llm_config"
require_relative "../shared/output_validator"
require "phronomy"

class StreamingAgent < Phronomy::Agent::Base
  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  instructions "You are a concise assistant. Answer in 2-3 sentences."
end

puts "=== Agent Streaming Example ==="
puts

query = "Briefly explain what the Ruby programming language is."
puts "Query: #{query}"
puts

print "Response: "

tokens_received = []
StreamingAgent.new.stream(query) do |event|
  case event.type
  when :token
    content = event.payload[:content]
    tokens_received << content if content
    print content if content
    $stdout.flush
  when :tool_call
    puts "\n[Tool call: #{event.payload[:tool_call].name}]"
  when :tool_result
    puts "[Tool result received]"
  when :done
    puts
    puts
    puts "--- Usage ---"
    puts "Input tokens:  #{event.payload[:usage].input}"
    puts "Output tokens: #{event.payload[:usage].output}"
  when :error
    puts "\nError: #{event.payload[:error].message}"
  end
end

OutputValidator.validate(
  "streaming produced non-empty token output",
  check: ->(_) { tokens_received.any? && tokens_received.join.length >= 20 }
) { [1] }
