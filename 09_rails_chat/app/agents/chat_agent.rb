# frozen_string_literal: true

class ChatAgent < Phronomy::Agent::Base
  agent_definition id: "example-09-chat-agent", version: 1

  model LLM_MODEL
  provider :openai
  tools CurrentTimeTool
  instructions "You are a helpful, concise assistant. Answer in the same language as the user."
end
