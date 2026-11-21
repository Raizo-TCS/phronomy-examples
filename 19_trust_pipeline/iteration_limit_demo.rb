#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../shared/llm_config"

class MissingEvidenceDraftAgent < Phronomy::Agent::Base
  agent_definition id: "example-19-missing-evidence-draft", version: 1
  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  instructions "Answer only from supplied documents. When no document supports the requested fact, " \
    "state that it is unknown, report zero confidence and do not invent citations."
end

class MissingEvidenceReviewAgent < Phronomy::Agent::Base
  agent_definition id: "example-19-missing-evidence-review", version: 1
  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  instructions <<~PROMPT
    You are a reviewer. Evaluate the supplied draft using only the supplied Sources.
    Do not answer the original question, provide a replacement answer, or invent prices, documents or citations.
    Approve only a draft that states a numeric shipping price supported by the supplied Sources.
    If Sources is empty or does not support a numeric shipping price stated in the draft,
    return approved: false and score: 0.0, and explain the missing evidence in feedback.
    Return only a JSON object with approved (boolean), score (number from 0.0 to 1.0),
    and feedback (string describing your evaluation of the draft).
  PROMPT
end

result = Phronomy::GeneratorVerifier.open(
  draft_agent: MissingEvidenceDraftAgent, review_agent: MissingEvidenceReviewAgent,
  draft_prompt_builder: ->(input, feedback) { "Question: #{input}. No document is available. Previous review: #{feedback}" },
  review_prompt_builder: ->(input, draft, citations) {
    "Review the following draft against the supplied Sources. The original question is context for your review.\n" \
      "Original question: #{input}\nDraft to evaluate: #{draft}\nSources: #{citations.inspect}"
  },
  confidence_threshold: 1.0, max_iterations: 1
) { |pipeline| pipeline.invoke_async("What is the numeric shipping price for the fictional missing region Z?") }

puts JSON.pretty_generate(result.to_h)
abort "Expected a valid evaluation to reach iteration_limit" unless result.termination_reason == "iteration_limit" && !result.accepted? && result.failure.nil?
