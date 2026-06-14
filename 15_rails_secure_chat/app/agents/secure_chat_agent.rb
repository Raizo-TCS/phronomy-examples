# frozen_string_literal: true

# Application-level prompt injection guardrail.
# PromptInjectionDetector was removed from phronomy; applications define
# their own patterns so policy decisions stay in application code.
class PromptInjectionGuardrail < Phronomy::Guardrail::InputGuardrail
  PATTERNS = [
    /ignore\s+(all\s+)?(previous|prior|above)\s+(instructions?|rules?|prompts?)/i,
    /disregard\s+(all\s+)?(previous|prior|above)\s+(instructions?|rules?|prompts?)/i,
    /forget\s+(all\s+)?(previous|prior|above)\s+(instructions?|rules?|prompts?)/i,
    /\bsystem\s*prompt\s*:/i,
    /\byou\s+are\s+now\s+(?:a|an)\b/i,
    /\bact\s+as\s+(?:a|an)\b/i,
    /\bpretend\s+(?:you\s+are|to\s+be)\b/i,
    /\bjailbreak\b/i,
    /\bdan\s*mode\b/i,
    /\bdev(?:eloper)?\s*mode\b/i
  ].freeze

  def check(value)
    text = value.to_s
    PATTERNS.each { |p| fail!("Potential prompt injection detected") if text.match?(p) }
  end
end

# Application-level PII guardrail (input side).
class PIIInputGuardrail < Phronomy::Guardrail::InputGuardrail
  PATTERNS = {
    credit_card: {pattern: /\b(?:\d{4}[- ]?){3}\d{4}\b/, label: "credit card number"},
    email: {pattern: /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/, label: "email address"},
    phone: {pattern: /(?:\+\d{1,3}[.\- ]?)?\(?\d{3}\)?[.\- ]?\d{3,4}[.\- ]?\d{4}\b/, label: "phone number"}
  }.freeze

  def check(value)
    text = value.to_s
    PATTERNS.each_value { |entry| fail!("PII detected in input: #{entry[:label]}") if text.match?(entry[:pattern]) }
  end
end

# Feature A (output side): reject LLM responses that contain PII patterns.
class PIIOutputGuardrail < Phronomy::Guardrail::OutputGuardrail
  PII_UNION = Regexp.union(*PIIInputGuardrail::PATTERNS.values.map { |v| v[:pattern] })

  def check(value)
    text = value.is_a?(Hash) ? value[:output].to_s : value.to_s
    fail!("PII detected in LLM output") if text.match?(PII_UNION)
  end
end

# Feature A + B: NIST AI RMF Govern/Map -- custom guardrails and caller identity.
# Guardrail instances are registered via add_input_filter / add_output_filter
# (they implement #call so they participate in the unified filter chain).
class SecureChatAgent < Phronomy::Agent::Base
  model LLM_MODEL
  provider :openai

  instructions "You are a helpful, concise assistant. Answer in the same language as the user."

  def initialize
    super
    # Feature A (input): block PII and prompt-injection attempts before reaching the LLM.
    add_input_filter PromptInjectionGuardrail.new
    add_input_filter PIIInputGuardrail.new
    # Feature A (output): block LLM responses that accidentally contain PII.
    add_output_filter PIIOutputGuardrail.new
  end
end
