#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../shared/llm_config"
require_relative "../shared/output_validator"
require_relative "agents"

# This example demonstrates the Generator-Verifier pattern with three trust mechanisms:
#   1. Citation Tracking  — DraftAgent cites knowledge sources in its JSON output.
#   2. Self-Review Loop   — ReviewAgent scores the draft; rejected answers are retried
#                           with the reviewer's feedback embedded in the next prompt.
#   3. Confidence Gate    — combined score (min of self-score and review-score) must
#                           meet the threshold; result exposes trusted? accordingly.
#
# The prompt builders below were previously provided by Phronomy::TrustPipeline.
# In v0.4.0, TrustPipeline was removed and GeneratorVerifier requires callers to
# supply their own prompt builders — this file serves as the reference implementation.

DRAFT_PROMPT_BUILDER = lambda do |input, feedback|
  lines = [
    "Answer the following question as accurately as possible.",
    "Use any knowledge provided in <context> tags and cite your sources."
  ]
  if feedback && !feedback.strip.empty?
    lines << ""
    lines << "Your previous draft was reviewed and rejected. Address ALL of this feedback:"
    lines << feedback.strip
  end
  lines += [
    "",
    "Question: #{input}",
    "",
    "RESPOND ONLY WITH VALID JSON (no text outside the JSON block):",
    '{"answer":"<full answer>","confidence":<0.0-1.0>,' \
      '"citations":[{"source":"<doc name>","excerpt":"<exact quote>"}]}'
  ]
  lines.join("\n")
end

REVIEW_PROMPT_BUILDER = lambda do |input, draft, citations|
  citation_text = if citations.empty?
    "  (none)"
  else
    citations.map { |c| "  - #{c[:source]}: \"#{c[:excerpt]}\"" }.join("\n")
  end
  [
    "You are a rigorous quality reviewer. Evaluate the draft answer below.",
    "",
    "Question: #{input}",
    "",
    "Draft answer:",
    draft.to_s,
    "",
    "Citations provided:",
    citation_text,
    "",
    "Evaluation criteria:",
    "  1. Is the answer factually accurate and complete?",
    "  2. Is every significant claim backed by a citation?",
    "  3. Is the self-reported confidence realistic?",
    "",
    "RESPOND ONLY WITH VALID JSON (no text outside the JSON block):",
    '{"approved":<true|false>,"score":<0.0-1.0>,' \
      '"feedback":"<specific actionable feedback, or empty string if approved>"}'
  ].join("\n")
end

pipeline = Phronomy::GeneratorVerifier.new(
  draft_agent:           PolicyDraftAgent,
  review_agent:          PolicyReviewAgent,
  draft_prompt_builder:  DRAFT_PROMPT_BUILDER,
  review_prompt_builder: REVIEW_PROMPT_BUILDER,
  confidence_threshold:  0.7,
  max_iterations:        3
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
  result = OutputValidator.validate(
    "trust pipeline scenario #{i + 1}: produces answer",
    check: ->(r) { r.output.length >= 20 }
  ) { pipeline.invoke(question) }
  print_result("Scenario #{i + 1}", result)
end
