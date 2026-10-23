#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "agents"
require_relative "llm_compatibility"

TrustLlmCompatibility.configure!

class ApprovedPolicyLookup < Phronomy::Tool::Base
  tool_name "approved_policy_lookup"
  description "Read the example refund policy after application approval."
  param :query, type: :string, desc: "The customer's policy question"
  requires_approval true

  def execute(query:)
    REFUND_POLICY
  end
end

class ApprovalPolicyDraftAgent < PolicyDraftAgent
  agent_definition id: "example-19-approved-policy-draft", version: 1
  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  tools ApprovedPolicyLookup => nil
  instructions "Call approved_policy_lookup exactly once before answering each question. " \
    "After its result arrives, answer from that result without calling another Tool. " \
    "Include confidence and supporting source excerpts."
end

events = Queue.new
result = Phronomy::GeneratorVerifier.open(
  draft_agent: ApprovalPolicyDraftAgent,
  review_agent: PolicyReviewAgent,
  draft_prompt_builder: ->(input, feedback) {
    "Question: #{input}\nPrevious review: #{feedback}\nReport confidence from 0 to 1 and cite supporting policy excerpts."
  },
  review_prompt_builder: ->(input, draft, citations) {
    "Review the answer for: #{input}\nAnswer: #{draft}\nSources: #{citations.inspect}\n" \
      "Report approval, a score from 0 to 1 and actionable review feedback."
  },
  max_iterations: 2,
  on_approval: ->(approval) { events << [:approval, approval] }
) do |pipeline|
  task = pipeline.invoke_async("What is the refund policy?")
  task.on_complete { |value, error| events << [:complete, [value, error]] }

  loop do
    type, payload = events.pop
    if type == :complete
      value, error = payload
      raise error if error
      break value
    end

    approval = payload
    puts JSON.pretty_generate(approval.to_h)
    puts "Allow these Tool operations? Enter yes, no, or cancel:"
    answer = $stdin.gets&.strip&.downcase
    if answer == "cancel"
      pipeline.cancel_async.wait_result
    else
      # The CLI owns this decision. Generation does not infer it from a
      # notification callback's return value.
      approval.respond_async(approved: answer == "yes").on_complete do |_value, error|
        warn "Approval response failed: #{error.message}" if error
      end
    end
  end
end

puts JSON.pretty_generate(result.to_h)
puts "Evaluation conditions met: #{result.accepted?}"
if result.failure
  warn "Output acquisition failed in #{result.interrupted_phase}: #{result.failure.fetch("code")} / #{result.failure.fetch("reason")}"
end
