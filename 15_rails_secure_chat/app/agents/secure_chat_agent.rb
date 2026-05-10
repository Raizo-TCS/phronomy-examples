# frozen_string_literal: true

# Feature A + B: NIST AI RMF Govern/Map — Builtin guardrails and caller identity.
# Guardrails are registered on each instance via #add_input_guardrail (instance API).
class SecureChatAgent < Phronomy::Agent::Base
  model LLM_MODEL
  provider :openai

  instructions "You are a helpful, concise assistant. Answer in the same language as the user."

  def initialize
    super
    # Feature A: block PII and prompt-injection attempts before reaching the LLM.
    add_input_guardrail Phronomy::Guardrail::Builtin::PromptInjectionDetector.new
    add_input_guardrail Phronomy::Guardrail::Builtin::PIIPatternDetector.new
  end
end
