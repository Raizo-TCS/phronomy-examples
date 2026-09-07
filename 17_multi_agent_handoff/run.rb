#!/usr/bin/env ruby
# frozen_string_literal: true

# 17 Multi-Agent Handoff
#
# Demonstrates Phronomy::Agent::HandoffRunner and explicit Handoff edges.
# A TriageAgent receives all user queries and may transfer responsibility to
# BillingAgent or TechSupportAgent through framework-generated handoff tools.

require_relative "../shared/llm_config"
require_relative "../shared/output_validator"
require "phronomy"
require_relative "agents"

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

  result = OutputValidator.validate(
    "handoff scenario #{i}: agent produces response",
    check: ->(r) { r[:output].length >= 20 }
  ) do
    # These are independent conversations. A runner reused across calls would
    # deliberately keep its current specialist as the active Agent.
    HandoffDemo.build_runner.invoke(scenario[:input])
  end

  puts "→ Handled by: #{result[:agent].class.name}"
  puts "Response: #{result[:output]}"
  puts
end

puts "Done."
