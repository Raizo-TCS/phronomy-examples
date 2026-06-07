#!/usr/bin/env ruby
# frozen_string_literal: true

# 16 Before-Completion Hook
#
# Demonstrates how before_completion hooks intercept every LLM call.
# Three hook levels are shown:
#
#   1. Global hook  — registered on Phronomy.configuration; fires for every agent
#   2. Class hook   — registered with the before_completion DSL on the agent class
#   3. Instance hook — set on a specific agent instance via attr_accessor
#
# Hooks receive a BeforeCompletionContext (agent, messages, config, params) and
# may return a Hash to merge into the LLM call params (e.g. temperature, stop).

require_relative "../shared/llm_config"
require_relative "../shared/output_validator"
require "phronomy"
require_relative "agents"

# ---------------------------------------------------------------------------
# Global hook: accumulate call count across all agents
# ---------------------------------------------------------------------------
call_log = []

Phronomy.configure do |cfg|
  cfg.before_completion = lambda do |ctx|
    entry = {agent: ctx.agent.class.name, model: ctx.params[:model], messages: ctx.messages.size}
    call_log << entry
    puts "  [global hook] agent=#{entry[:agent]} model=#{entry[:model]} messages=#{entry[:messages]}"
    nil # no param override from this hook
  end
end

puts "=== 16 Before-Completion Hook ===\n\n"

# ---------------------------------------------------------------------------
# Scenario 1: Global hook — runs for every LLM call
# ---------------------------------------------------------------------------
puts "--- Scenario 1: Global hook (call logging) ---"
agent1 = LoggingAgent.new
result1a = OutputValidator.validate(
  "scenario 1a: agent answers capital of France",
  check: ->(r) { r[:output].length >= 5 }
) { agent1.invoke("What is the capital of France?") }
puts "  Result: #{result1a[:output]}\n\n"

result1b = OutputValidator.validate(
  "scenario 1b: agent answers arithmetic",
  check: ->(r) { r[:output].length >= 1 }
) { agent1.invoke("What is 2 + 2?") }
puts "  Result: #{result1b[:output]}\n\n"

puts "  Calls logged so far: #{call_log.size}\n\n"

OutputValidator.validate(
  "global hook captured at least 2 LLM calls",
  check: ->(_) { call_log.size >= 2 }
) { [1] }

# ---------------------------------------------------------------------------
# Scenario 2: Class-level hook — DeterministicAgent forces temperature=0.0
# ---------------------------------------------------------------------------
puts "--- Scenario 2: Class-level hook (temperature override) ---"
result2 = DeterministicAgent.new.invoke("Name one planet in the solar system.")
puts "  Result: #{result2[:output]}\n\n"

# ---------------------------------------------------------------------------
# Scenario 3: Instance-level hook — override for one specific instance only
# ---------------------------------------------------------------------------
puts "--- Scenario 3: Instance-level hook (per-instance temperature) ---"
creative = LoggingAgent.new
creative.before_completion = lambda do |ctx|
  puts "  [instance hook] #{ctx.agent.class.name}: temperature -> 1.0 (creative mode)"
  {temperature: 1.0}
end

result3 = creative.invoke("Give me a creative name for a robot.")
puts "  Result: #{result3[:output]}\n\n"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
puts "--- Summary ---"
puts "Total LLM calls intercepted by global hook: #{call_log.size}"
call_log.each.with_index(1) do |entry, i|
  puts "  ##{i}: #{entry[:agent]} (#{entry[:messages]} messages)"
end
puts "\nDone."

# Restore global config so this example is side-effect-free when loaded in tests
Phronomy.configure { |cfg| cfg.before_completion = nil }
