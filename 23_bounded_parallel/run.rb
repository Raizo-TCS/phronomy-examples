# frozen_string_literal: true

# 23 Bounded Parallel Dispatch
#
# Demonstrates the concurrency control keyword arguments added to
# Phronomy::MultiAgent::Orchestrator#dispatch_parallel and #fan_out in v0.5.4:
#
#   max_concurrency: N  — cap the number of concurrent worker threads
#   on_error: :skip     — fill failed task slots with nil; never raise
#   on_error: :raise    — re-raise the first error in input order after all
#                         tasks complete (default)
#
# Scenario: a product-review pipeline that runs sentiment analysis on five
# reviews using a bounded thread pool (fan_out), then dispatches two different
# agents on selected reviews simultaneously (dispatch_parallel).

require_relative "../shared/llm_config"
require_relative "../shared/output_validator"
require "phronomy"
require_relative "agents"

REVIEWS = [
  "Absolutely love this product! Fast shipping and great quality.",
  "Terrible experience. Broke after one day of use.",
  "Decent product, nothing special. Does exactly what it says.",
  "Best purchase I've made this year. Highly recommend to everyone.",
  "Not as described at all. Very disappointed with this purchase."
].freeze

orchestrator = ReviewOrchestrator.new

puts "=== 23 Bounded Parallel Dispatch ===\n\n"

# ── Part 1: fan_out — same agent, 5 inputs, max 3 concurrent threads ─────────
puts "[1] Sentiment analysis — fan_out, max_concurrency: 3\n\n"

sentiments = OutputValidator.validate(
  "fan_out returns 5 sentiment results",
  check: ->(r) { r.compact.size >= 3 && r.compact.all? { |x| x[:output].length >= 5 } }
) { orchestrator.analyze_sentiments(REVIEWS) }

sentiments.each_with_index do |result, i|
  if result
    puts "  Review #{i + 1}: #{result[:output]}"
  else
    puts "  Review #{i + 1}: (skipped — agent returned nil)"
  end
end

puts

# ── Part 2: dispatch_parallel — 2 different agents, max 2 concurrent threads ─
puts "[2] Mixed analysis — dispatch_parallel, max_concurrency: 2\n\n"

analyses = OutputValidator.validate(
  "dispatch_parallel returns 2 analysis results",
  check: ->(r) { r.compact.size >= 1 && r.compact.all? { |x| x[:output].length >= 5 } }
) { orchestrator.mixed_analysis(REVIEWS) }

labels = ["Sentiment [review 1]", "Keywords [review 2]"]
analyses.each_with_index do |result, i|
  if result
    puts "  #{labels[i]}: #{result[:output]}"
  else
    puts "  #{labels[i]}: (skipped)"
  end
end

puts "\nDone."
