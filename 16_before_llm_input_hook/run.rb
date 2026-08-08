#!/usr/bin/env ruby
# frozen_string_literal: true

# 16 Before-LLM-Input Hook
#
# Demonstrates how before_llm_input hooks customize every LLM call before
# the Manifest is finalized. Three hook levels are shown:
#
#   1. Global hook  — registered on Phronomy.configuration; fires for every agent
#   2. Class hook   — registered with the before_llm_input DSL on the agent class
#   3. Instance hook — set on a specific agent instance via attr_accessor
#
# Hooks receive an LLMInputBuildContext (agent_id, agent_definition_id,
# definition_version, config, call_sequence) and must return an LLMInputPatch
# or nil. The Patch expresses model_config overrides (temperature, etc.) and
# optional segment_candidates to inject into the context.
#
# Key difference from the old before_completion API:
#   - No access to RubyLLM::Chat, messages arrays, or provider objects
#   - Returns a typed LLMInputPatch instead of a plain Hash
#   - Applied BEFORE the Manifest is written, so it is part of the audit log
#   - Runs before EVERY LLM call (initial and tool-loop follow-ups)

require_relative "../shared/llm_config"
require_relative "../shared/output_validator"
require "phronomy"
require_relative "agents"

# ---------------------------------------------------------------------------
# Global hook: accumulate call count across all agents
# ---------------------------------------------------------------------------
call_log = []

Phronomy.configure do |cfg|
  cfg.before_llm_input = lambda do |ctx|
    entry = {
      agent_id: ctx.agent_id,
      definition_id: ctx.agent_definition_id,
      call_sequence: ctx.call_sequence
    }
    call_log << entry
    puts "  [global hook] #{entry[:definition_id]} call=#{entry[:call_sequence]}"
    nil # no override from this hook
  end
end

puts "=== 16 Before-LLM-Input Hook ===\n\n"

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
puts "--- Scenario 2: Class-level hook (temperature override via LLMInputPatch) ---"
result2 = DeterministicAgent.new.invoke("Name one planet in the solar system.")
puts "  Result: #{result2[:output]}\n\n"

# ---------------------------------------------------------------------------
# Scenario 3: Instance-level hook — override for one specific instance only
# ---------------------------------------------------------------------------
puts "--- Scenario 3: Instance-level hook (per-instance temperature) ---"
creative = LoggingAgent.new
creative.before_llm_input = lambda do |ctx|
  puts "  [instance hook] #{ctx.agent_definition_id} call=#{ctx.call_sequence}: temperature -> 1.0"
  Phronomy::Agent::LLMInputPatch.new(
    model_config_patch: {temperature: 1.0}
  )
end

result3 = creative.invoke("Give me a creative name for a robot.")
puts "  Result: #{result3[:output]}\n\n"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
puts "--- Summary ---"
puts "Total LLM calls intercepted by global hook: #{call_log.size}"
call_log.each.with_index(1) do |entry, i|
  puts "  ##{i}: #{entry[:definition_id]} (call_sequence=#{entry[:call_sequence]})"
end
puts "\nDone."

# Restore global config so this example is side-effect-free when loaded in tests
Phronomy.configure { |cfg| cfg.before_llm_input = nil }
