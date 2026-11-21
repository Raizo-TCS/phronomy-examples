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
require "phronomy"
require_relative "agents"

task = "Write a technical blog post about Ruby 3.4 new features."

puts "=== Multi-Agent Example ==="
puts "TaskResult: #{task}"
puts
puts "[config] Model:              #{LLMConfig::MODEL}"
allocation = Example05Budget.current
puts "[config] Registered context: #{allocation.context_window}; output cap: #{allocation.output_tokens}"
puts "[config] Input allowance: #{allocation.input_tokens}; safety margin: #{allocation.safety_margin}"
puts "[config] Reasoning models may consume this budget before producing final-answer text."
puts "[config] LLM calls expected: 3+ (Orchestrator drives tool calls autonomously)"
puts

llm_call_count = 0

Phronomy.configuration.before_llm_input = ->(ctx) {
  llm_call_count += 1
  budget = Example05Budget.current
  puts "  [LLM call ##{llm_call_count}] agent=#{ctx.agent_definition_id} " \
       "call_seq=#{ctx.call_sequence} output_cap=#{budget.output_tokens} input_allowance=#{budget.input_tokens}"
  puts "  [LLM call ##{llm_call_count}] accumulated tool result chars: #{$accumulated_tool_chars || 0}"
  nil
}

t_total = Time.now

result = Phronomy::Agent.open_scope { |agents| agents.create(OrchestratorAgent).invoke_async(task) }
article = Example05Validation.article!(result)
puts "[validate] OK: nonblank research passed to the writer; publishing its verified result"

puts
puts "--- Final Article ---"
puts article
puts
puts "[summary] Total LLM calls: #{llm_call_count}, total elapsed: #{(Time.now - t_total).round(1)}s"
