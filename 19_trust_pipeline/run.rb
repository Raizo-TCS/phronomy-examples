#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../shared/llm_config"
require_relative "agents"

DRAFT_PROMPT_BUILDER = lambda do |input, feedback|
  lines = [
    "Answer the following question as accurately as possible.",
    "Use the Agent's persistent Knowledge and cite the embedded Source names.",
    "Report your confidence from 0 to 1 and the supporting source excerpts."
  ]
  unless feedback.nil? || feedback.empty?
    lines << "Address the previous review feedback: #{feedback}"
  end
  lines << "Question: #{input}"
  lines.join("\n")
end

REVIEW_PROMPT_BUILDER = lambda do |input, draft, citations|
  citation_text = if citations.empty?
    "  (none)"
  else
    citations.map { |c| "  - #{c.fetch("source")}: #{c.fetch("excerpt")}" }.join("\n")
  end
  [
    "Evaluate the draft answer for accuracy, completeness, and source support.",
    "Approve it only when its significant claims have adequate support.",
    "Report a score from 0 to 1 and actionable feedback.",
    "Question: #{input}",
    "Draft: #{draft}",
    "Citations:",
    citation_text
  ].join("\n")
end

def with_pipeline(&block)
  Phronomy::GeneratorVerifier.open(
    draft_agent: PolicyDraftAgent,
    review_agent: PolicyReviewAgent,
    draft_prompt_builder: DRAFT_PROMPT_BUILDER,
    review_prompt_builder: REVIEW_PROMPT_BUILDER,
    confidence_threshold: 0.7,
    max_iterations: 3,
    &block
  )
end

SCENARIOS = [
  "What is the refund policy? How many days do I have to return an item?",
  "How long does express shipping take, and how much does it cost?",
  "Can I get a refund after 60 days if the item is unused?"
].freeze

def print_result(result)
  puts "Reason: #{result.termination_reason}"
  puts "Accepted: #{result.accepted?}"
  puts "Output: #{result.output}" unless result.output.nil?
  if result.failure
    puts "Output acquisition failed in #{result.interrupted_phase}:"
    puts "  #{result.failure.fetch("code")} / #{result.failure.fetch("reason")}"
    return
  end
  if result.termination_reason == "tool_rejected"
    puts "A Tool was denied in #{result.interrupted_phase}; evaluation is incomplete."
    return
  end
  puts "Confidence: #{format("%.2f", result.confidence)}"
  result.citations.each do |citation|
    puts "  #{citation.fetch("source")}: #{citation.fetch("excerpt")}"
  end
end

SCENARIOS.each do |question|
  puts "Question: #{question}"
  result = with_pipeline do |pipeline|
    pipeline.invoke_async(question)
  end
  print_result(result)
  puts
end
