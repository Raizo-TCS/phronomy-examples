# frozen_string_literal: true

# Application-specific PII policy built on the public 0.17 Filter boundary.
class PIIInputFilter < Phronomy::Filter::Base
  PATTERNS = {
    credit_card: {pattern: /\b(?:\d{4}[- ]?){3}\d{4}\b/, label: "credit card number"},
    email: {pattern: /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/, label: "email address"},
    phone: {pattern: /(?:\+\d{1,3}[.\- ]?)?\(?\d{3}\)?[.\- ]?\d{3,4}[.\- ]?\d{4}\b/, label: "phone number"}
  }.freeze

  def call(value, **_context)
    text = value.to_s
    PATTERNS.each_value do |entry|
      block!("PII detected in input: #{entry[:label]}") if text.match?(entry[:pattern])
    end
    value
  end
end

class PIIOutputFilter < Phronomy::Filter::Base
  PII_UNION = Regexp.union(*PIIInputFilter::PATTERNS.values.map { |entry| entry[:pattern] })

  def call(value, **_context)
    text = value.to_s
    block!("PII detected in LLM output") if text.match?(PII_UNION)
    value
  end
end

class SecureChatAgent < Phronomy::Agent::Base
  agent_definition id: "example-15-secure-chat-agent", version: 2

  model LLM_MODEL
  provider :openai
  instructions "You are a helpful, concise assistant. Answer in the same language as the user."

  # Framework-provided prompt-injection defense-in-depth plus application
  # extensions used by this demo's scenario tests.
  input_filter Phronomy::Filter::PromptInjectionFilter.new(
    extra_patterns: [
      /ignore\s+all\s+(previous|prior)\s+instructions?/i,
      /\bsystem\s*prompt\s*:/i,
      /\bjailbreak\b/i
    ]
  )
  input_filter PIIInputFilter
  output_filter PIIOutputFilter
end
