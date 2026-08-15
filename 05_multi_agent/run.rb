#!/usr/bin/env ruby
# frozen_string_literal: true

# 05 Multi-Agent (LLM-Driven Coordination)
#
# Demonstrates the "Agent-as-Tool" pattern: sub-agents are wrapped as
# tools so the orchestrator LLM decides autonomously when and how to
# call them, rather than following a hardcoded execution order.
#
# Contrast with a Workflow-based fixed pipeline:
#   app = Phronomy::Workflow.define(MyContext) do
#     state :research, action: RESEARCH_NODE
#     state :write,    action: WRITE_NODE
#     after :research, to: :write
#   end
#
# Here the orchestrator LLM drives coordination via tool calls.

require_relative "../shared/llm_config"
require_relative "../shared/output_validator"
require "phronomy"
require_relative "agents"

task = "Write a technical blog post about Ruby 3.4 new features."

puts "=== Multi-Agent Example ==="
puts "Task: #{task}"
puts
puts "[config] Model:                #{LLMConfig::MODEL}"
puts "[config] OrchestratorAgent:    max_output_tokens=2048 (tool calls + article passthrough)"
puts "[config] ResearcherAgent:      max_output_tokens=#{RESEARCHER_MAX_TOKENS} tokens (~400 words)"
puts "[config] WriterAgent:          max_output_tokens=#{WRITER_MAX_TOKENS} tokens (~1500 words)"
puts "[config] LLM calls expected:   3+ (Orchestrator drives tool calls autonomously)"
puts

llm_call_count = 0

# Map agent definition IDs to their configured max_output_tokens for logging.
agent_max_tokens = {
  "example-05-orchestrator-agent" => OrchestratorAgent.max_output_tokens,
  "example-05-researcher-agent"   => ResearcherAgent.max_output_tokens,
  "example-05-writer-agent"       => WriterAgent.max_output_tokens
}

Phronomy.configuration.before_llm_input = ->(ctx) {
  llm_call_count += 1
  max_tok = agent_max_tokens[ctx.agent_definition_id] || "(not set)"
  puts "  [LLM call ##{llm_call_count}] agent=#{ctx.agent_definition_id} " \
       "call_seq=#{ctx.call_sequence} max_output_tokens=#{max_tok}"
  puts "  [LLM call ##{llm_call_count}] accumulated tool result chars: #{$accumulated_tool_chars || 0}"
  nil
}

t_total = Time.now

result = OutputValidator.validate(
  "multi-agent produces article of 300+ chars",
  check: ->(r) { r[:output].length >= 300 }
) { OrchestratorAgent.new.invoke(task) }

puts
puts "--- Final Article ---"
puts result[:output]
puts
puts "[summary] Total LLM calls: #{llm_call_count}, total elapsed: #{(Time.now - t_total).round(1)}s"
