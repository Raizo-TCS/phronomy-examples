# frozen_string_literal: true

require_relative "../shared/llm_config"
require "phronomy"

REFUND_POLICY = File.read(File.join(__dir__, "knowledge/refund_policy.md"))
SHIPPING_POLICY = File.read(File.join(__dir__, "knowledge/shipping_policy.md"))

# DraftAgent: answers customer questions using Journal-backed persistent
# Knowledge. Knowledge is a context candidate; it is not injected as a mutable
# provider message array and it does not appear in #transcript.
class PolicyDraftAgent < Phronomy::Agent::Base
  agent_definition id: "example-19-policy-draft-agent", version: 2

  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER

  instructions <<~PROMPT
    You are a helpful customer support assistant for Acme Corp.
    Answer only from the policy knowledge supplied in context.
    Cite the source label in your answer.
    If the policy does not cover the question, say so.
  PROMPT

  def initialize(knowledge: [], **kwargs)
    policy_knowledge = [
      "Source: refund_policy.md\n#{REFUND_POLICY}",
      "Source: shipping_policy.md\n#{SHIPPING_POLICY}"
    ]

    super(knowledge: policy_knowledge + Array(knowledge), **kwargs)
  end
end

# ReviewAgent: evaluates draft answers for accuracy and citation quality.
class PolicyReviewAgent < Phronomy::Agent::Base
  agent_definition id: "example-19-policy-review-agent", version: 1

  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER

  instructions "Verify customer-support answers for accuracy, completeness, and source citations."
end
