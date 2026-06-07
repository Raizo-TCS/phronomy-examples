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

result = OutputValidator.validate(
  "multi-agent produces article of 300+ chars",
  check: ->(r) { r[:output].length >= 300 }
) { OrchestratorAgent.new.invoke(task) }

puts
puts "--- Final Article ---"
puts result[:output]
