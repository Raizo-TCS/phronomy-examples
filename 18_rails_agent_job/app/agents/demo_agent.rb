# frozen_string_literal: true

# The agent that powers this demo chat.
# Uses the shared LLM config so no credentials are hardcoded here.
require_relative "../../../shared/llm_config"

class DemoAgent < Phronomy::Agent::Base
  agent_definition id: "example-18-demo-agent", version: 1

  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  instructions "You are a helpful assistant. Be concise — answer in 2-3 sentences."
end
