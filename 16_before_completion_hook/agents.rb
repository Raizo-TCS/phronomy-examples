# frozen_string_literal: true

require_relative "../shared/llm_config"
require "phronomy"

# ---------------------------------------------------------------------------
# Agent definitions
# ---------------------------------------------------------------------------

class LoggingAgent < Phronomy::Agent::Base
  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  instructions "You are a concise assistant. Answer in one sentence."
end

class DeterministicAgent < Phronomy::Agent::Base
  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  instructions "You are a concise assistant. Answer in one sentence."

  # Class-level hook: force temperature=0.0 for fully deterministic responses.
  before_completion ->(ctx) {
    puts "  [class hook] #{ctx.agent.class.name}: setting temperature=0.0"
    {temperature: 0.0}
  }
end
