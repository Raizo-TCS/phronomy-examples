# frozen_string_literal: true

require_relative "../shared/llm_config"
require "phronomy"

REFUND_POLICY  = File.read(File.join(__dir__, "knowledge/refund_policy.md"))
SHIPPING_POLICY = File.read(File.join(__dir__, "knowledge/shipping_policy.md"))

# DraftAgent: answers customer questions using the policy knowledge base.
# Static knowledge sources are attached with source labels so the agent
# can produce grounded citations in its JSON output.
class PolicyDraftAgent < Phronomy::Agent::Base
  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER

  instructions "You are a helpful customer support assistant for Acme Corp. " \
    "Answer questions using only the knowledge provided in the <context> tags. " \
    "If the knowledge does not cover the question, say so honestly."

  static_knowledge(
    Phronomy::Agent::Context::Knowledge::StaticKnowledge.new(
      REFUND_POLICY,
      type: :policy,
      source: "refund_policy.md"
    ),
    Phronomy::Agent::Context::Knowledge::StaticKnowledge.new(
      SHIPPING_POLICY,
      type: :policy,
      source: "shipping_policy.md"
    )
  )
end

# ReviewAgent: evaluates draft answers for accuracy and citation quality.
class PolicyReviewAgent < Phronomy::Agent::Base
  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER

  instructions "You are a rigorous quality reviewer for customer support answers. " \
    "Your job is to verify that answers are accurate, complete, and properly cited."
end
