#!/usr/bin/env ruby
# frozen_string_literal: true

# 05 Multi-Agent (LLM-Driven Coordination)
#
# Demonstrates the "Agent-as-Tool" pattern: sub-agents are wrapped as
# tools so the orchestrator LLM decides autonomously when and how to
# call them, rather than following a hardcoded execution order.
#
# Contrast with a Graph-based fixed pipeline:
#   graph.add_node(:research) { |s| ... }
#   graph.add_node(:write)    { |s| ... }
#   graph.add_edge(:research, :write)
#
# Here the orchestrator LLM drives coordination via tool calls.

require_relative "../shared/llm_config"
require "phronomy"
require_relative "agents"

task = "Write a technical blog post about Ruby 3.4 new features."

puts "=== Multi-Agent Example ==="
puts "Task: #{task}"
puts

result = OrchestratorAgent.new.invoke(task)

puts
puts "--- Final Article ---"
puts result[:output]
