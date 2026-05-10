#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../shared/llm_config"
require_relative "agents"

# Phronomy::TrustPipeline combines three trust mechanisms:
#   1. Citation Tracking  — DraftAgent cites knowledge sources in its JSON output.
#   2. Self-Review Loop   — ReviewAgent scores the draft; rejected answers are retried
#                           with the reviewer's feedback embedded in the next prompt.
#   3. Confidence Gate    — combined score (min of self-score and review-score) must
#                           meet the threshold; result exposes trusted? accordingly.

pipeline = Phronomy::TrustPipeline.new(
  draft_agent:          PolicyDraftAgent,
  review_agent:         PolicyReviewAgent,
  confidence_threshold: 0.7,
  max_iterations:       3
)

SCENARIOS = [
  "What is the refund policy? How many days do I have to return an item?",
  "How long does express shipping take, and what does it cost?",
  "Can I get a refund after 60 days if the item is unused?"
].freeze

def print_result(label, result)
  puts "=== #{label} ==="
  puts "Output    : #{result.output}"
  puts "Trusted   : #{result.trusted?}"
  puts format("Confidence: %.2f", result.confidence)
  puts "Iterations: #{result.iterations}"
  if result.citations.any?
    puts "Citations :"
    result.citations.each { |c| puts "  - #{c[:source]}: \"#{c[:excerpt]}\"" }
  else
    puts "Citations : (none)"
  end
  puts
end

SCENARIOS.each_with_index do |question, i|
  puts "Question #{i + 1}: #{question}"
  result = pipeline.invoke(question)
  print_result("Scenario #{i + 1}", result)
end
