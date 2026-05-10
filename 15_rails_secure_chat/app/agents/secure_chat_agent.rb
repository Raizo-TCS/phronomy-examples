# frozen_string_literal: true

# Feature A (output side): reject LLM responses that contain PII patterns.
# Reuses the same pattern set as PIIPatternDetector to maintain consistency.
class PIIOutputGuardrail < Phronomy::Guardrail::OutputGuardrail
  PII_UNION = Regexp.union(
    *Phronomy::Guardrail::Builtin::PIIPatternDetector::PATTERNS.values.map { |v| v[:pattern] }
  )

  def check(value)
    text = value.is_a?(Hash) ? value[:output].to_s : value.to_s
    fail!("PII detected in LLM output") if text.match?(PII_UNION)
  end
end

# Feature A + B: NIST AI RMF Govern/Map -- Builtin guardrails and caller identity.
# Guardrails are registered on each instance via #add_input_guardrail (instance API).
class SecureChatAgent < Phronomy::Agent::Base
  model LLM_MODEL
  provider :openai

  instructions "You are a helpful, concise assistant. Answer in the same language as the user."

  def initialize
    super
    # Feature A (input): block PII and prompt-injection attempts before reaching the LLM.
    add_input_guardrail Phronomy::Guardrail::Builtin::PromptInjectionDetector.new
    add_input_guardrail Phronomy::Guardrail::Builtin::PIIPatternDetector.new
    # Feature A (output): block LLM responses that accidentally contain PII.
    add_output_guardrail PIIOutputGuardrail.new
  end
end
