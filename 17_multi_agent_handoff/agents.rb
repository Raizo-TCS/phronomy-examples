# frozen_string_literal: true

require_relative "../shared/llm_config"
require "phronomy"

# ---------------------------------------------------------------------------
# Specialist agents
# ---------------------------------------------------------------------------

class TriageAgent < Phronomy::Agent::Base
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
  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  instructions <<~TEXT
    You are a billing specialist. Help users with invoice questions, payment issues, and charge disputes.
    Be concise and empathetic. Answer in 2-3 sentences.
  TEXT
end

class TechSupportAgent < Phronomy::Agent::Base
  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  instructions <<~TEXT
    You are a technical support specialist. Help users diagnose and resolve software errors and crashes.
    Provide actionable steps in 2-3 sentences.
  TEXT
end
