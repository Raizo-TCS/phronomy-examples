#!/usr/bin/env ruby
# frozen_string_literal: true

# 17 Multi-Agent Handoff
#
# Demonstrates Phronomy::Agent::Runner for hub-and-spoke routing.
# A TriageAgent receives all user queries and transfers them to the appropriate
# specialist (BillingAgent or TechSupportAgent) via auto-generated handoff tools.
#
# result[:agent] reports which agent produced the final answer.

require_relative "../shared/llm_config"
require "phronomy"
require_relative "agents"

# ---------------------------------------------------------------------------
# Build the runner: triage is the entry point, routes to both specialists
# ---------------------------------------------------------------------------
triage      = TriageAgent.new
billing     = BillingAgent.new
tech        = TechSupportAgent.new

runner = Phronomy::Agent::Runner.new(
  agents: [triage, billing, tech],
  routes: {triage => [billing, tech]}
)

puts "=== 17 Multi-Agent Handoff ===\n\n"

SCENARIOS = [
  {
    label: "Billing query",
    input: "I was charged twice on my last invoice and need a refund."
  },
  {
    label: "Technical query",
    input: "My app keeps crashing with a NoMethodError on nil. How do I debug this?"
  },
  {
    label: "General query (stays at triage)",
    input: "What are your customer support business hours?"
  }
].freeze

SCENARIOS.each.with_index(1) do |scenario, i|
  puts "--- Scenario #{i}: #{scenario[:label]} ---"
  puts "User: \"#{scenario[:input]}\""

  result = runner.invoke(scenario[:input])

  puts "→ Handled by: #{result[:agent].class.name}"
  puts "Response: #{result[:output]}"
  puts
end

puts "Done."
