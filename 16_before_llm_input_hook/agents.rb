# frozen_string_literal: true

require_relative "../shared/llm_config"
require "phronomy"

# ---------------------------------------------------------------------------
# LoggingAgent — no hook; used to demonstrate the global hook firing for
# every agent, not just those with a class-level hook.
# ---------------------------------------------------------------------------

class LoggingAgent < Phronomy::Agent::Base
  agent_definition id: "example-16-logging-agent", version: 1

  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  instructions "You are a concise assistant. Answer in one sentence."
end

# ---------------------------------------------------------------------------
# DeterministicAgent — class-level hook forces temperature=0.0.
# The hook receives an LLMInputBuildContext (agent_id, agent_definition_id,
# definition_version, config, call_sequence) and returns an LLMInputPatch.
# ---------------------------------------------------------------------------

class DeterministicAgent < Phronomy::Agent::Base
  agent_definition id: "example-16-deterministic-agent", version: 1

  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  instructions "You are a concise assistant. Answer in one sentence."

  before_llm_input ->(ctx) {
    puts "  [class hook] #{ctx.agent_definition_id} call=#{ctx.call_sequence}: setting temperature=0.0"
    Phronomy::Agent::LLMInputPatch.new(
      model_config_patch: {temperature: 0.0}
    )
  }
end
