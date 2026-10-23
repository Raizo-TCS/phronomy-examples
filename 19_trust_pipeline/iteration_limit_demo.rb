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
  instructions "The acceptance criterion is a documented numeric shipping price. " \
    "Reject an answer without that evidence and explain what is missing."
end

result = Phronomy::GeneratorVerifier.open(
  draft_agent: MissingEvidenceDraftAgent, review_agent: MissingEvidenceReviewAgent,
  draft_prompt_builder: ->(input, feedback) { "Question: #{input}. No document is available. Previous review: #{feedback}" },
  review_prompt_builder: ->(input, draft, citations) { "Question: #{input}. Draft: #{draft}. Sources: #{citations.inspect}" },
  confidence_threshold: 1.0, max_iterations: 1
) { |pipeline| pipeline.invoke_async("What is the numeric shipping price for the fictional missing region Z?") }

puts JSON.pretty_generate(result.to_h)
abort "Expected a valid evaluation to reach iteration_limit" unless result.termination_reason == "iteration_limit" && !result.accepted? && result.failure.nil?
