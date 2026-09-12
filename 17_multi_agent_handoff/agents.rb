# frozen_string_literal: true

require_relative "../shared/llm_config"
require "phronomy"

# ---------------------------------------------------------------------------
# Specialist agents
# ---------------------------------------------------------------------------

class TriageAgent < Phronomy::Agent::Base
  agent_definition id: "example-17-triage-agent", version: 1

  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  instructions <<~TEXT
    You are a customer support triage agent.
    When a user asks about billing, invoices, payments, or charges, transfer to the billing agent.
    When a user asks about technical issues, bugs, crashes, or errors, transfer to the tech support agent.
    For all other queries, answer directly and concisely.
  TEXT
end

class BillingAgent < Phronomy::Agent::Base
  agent_definition id: "example-17-billing-agent", version: 1

  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  instructions <<~TEXT
    You are a billing specialist. Help users with invoice questions, payment issues, and charge disputes.
    Be concise and empathetic. Answer in 2-3 sentences.
  TEXT
end

class TechSupportAgent < Phronomy::Agent::Base
  agent_definition id: "example-17-tech-support-agent", version: 1

  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  instructions <<~TEXT
    You are a technical support specialist. Help users diagnose and resolve software errors and crashes.
    Provide actionable steps in 2-3 sentences.
  TEXT
end

# Each runner represents one conversation. Every participant shares its exact
# Persistence instance; reusing this runner continues with the active specialist.
module HandoffDemo
  def self.build_runner(persistence: Phronomy::Persistence::InMemory.new)
    triage = TriageAgent.new(persistence: persistence)
    billing = BillingAgent.new(persistence: persistence)
    tech = TechSupportAgent.new(persistence: persistence)
    handoffs = [
      Phronomy::Agent::Handoff.new(source_agent: triage, target_agent: billing,
        description: "Transfer billing, invoice, payment, refund, or charge-dispute requests."),
      Phronomy::Agent::Handoff.new(source_agent: triage, target_agent: tech,
        description: "Transfer software errors, crashes, bugs, and technical-support requests.")
    ]
    Phronomy::Agent::HandoffRunner.new(main_agent: triage, handoffs: handoffs)
  end
end
