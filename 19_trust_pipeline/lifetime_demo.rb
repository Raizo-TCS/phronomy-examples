#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "agents"

result = Phronomy::GeneratorVerifier.open(
  draft_agent: PolicyDraftAgent,
  review_agent: PolicyReviewAgent,
  draft_prompt_builder: lambda { |input, feedback|
    "Answer #{input}. Address feedback #{feedback}. " \
      "Report confidence from 0 to 1 and supporting source excerpts."
  },
  review_prompt_builder: lambda { |input, draft, citations|
    "Review #{draft} for #{input}, using #{citations.inspect}. " \
      "Report approval, a score from 0 to 1, and actionable feedback."
  }
) do |pipeline|
  pipeline.invoke_async("How many days do I have to return an item?")
end

puts result.termination_reason
