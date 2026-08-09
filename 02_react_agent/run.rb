#!/usr/bin/env ruby
# frozen_string_literal: true

# 02 ReAct Agent
#
# Demonstrates an Agent that can decide when to call tools and then continue
# reasoning with the tool results.

require_relative "../shared/llm_config"
require_relative "../shared/output_validator"
require_relative "tools"
require "phronomy"

class AssistantAgent < Phronomy::Agent::Base
  agent_definition id: "example-02-assistant-agent", version: 2

  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  instructions <<~PROMPT
    You are a concise assistant.
    Use the available tools whenever they are needed to answer accurately.
  PROMPT

  tools(
    GetCurrentTimeTool => nil,
    GetWeatherTool => nil
  )
end

puts "=== ReAct Agent Example ==="
puts

question = ARGV.empty? ?
  "What time is it now, and what is the weather in Tokyo?" :
  ARGV.join(" ")

puts "Question: #{question}"

events = []
result = OutputValidator.validate(
  "ReAct agent returns a non-empty answer",
  check: ->(r) { r[:output].to_s.length >= 20 }
) do
  AssistantAgent.new.invoke(
    question,
    on_event: ->(event) { events << event }
  )
end

tool_events = events.select { |event| event.type == :tool_call }

puts
puts "Answer:"
puts result[:output]
puts
puts "Tool calls: #{tool_events.length}"
tool_events.each do |event|
  tool_call = event.payload[:tool_call]
  puts "  - #{tool_call.name}"
end
puts "Execution: #{result[:execution_id]}"
puts "Journal position after execution: #{result[:journal_position]}"
