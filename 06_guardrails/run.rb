#!/usr/bin/env ruby
# frozen_string_literal: true

# 06 Guardrails
#
# Demonstrates Input/Output guardrails on an Agent:
#   - NoPIIInputGuardrail rejects inputs containing 12-digit numbers
#     (Japanese My Number format).
#   - NoURLOutputGuardrail rejects outputs containing http(s) URLs.

require_relative "../shared/llm_config"
require "phronomy"

class NoPIIInputGuardrail < Phronomy::Guardrail::InputGuardrail
  def check(value)
    text = value.is_a?(Hash) ? value.values.map(&:to_s).join(" ") : value.to_s
    fail!("PII detected in input") if text.match?(/\d{12}/)
  end
end

class NoURLOutputGuardrail < Phronomy::Guardrail::OutputGuardrail
  def check(value)
    text = value.is_a?(Hash) ? value[:output].to_s : value.to_s
    fail!("URL detected in output") if text.match?(%r{https?://})
  end
end

class SafeQAAgent < Phronomy::Agent::Base
  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  instructions "You are a polite QA assistant. Answer concisely."
end

def ask(agent, question)
  puts "Q: #{question}"
  result = agent.invoke(question)
  puts "A: #{result[:output]}"
rescue Phronomy::GuardrailError => e
  puts "ERROR: GuardrailError (#{e.guardrail.class.name}): #{e.message}"
end

puts "=== Guardrails Example ==="

# Case 1: Normal — should succeed.
puts
puts "[Case 1 - Normal]"
agent = SafeQAAgent.new
agent.add_input_guardrail(NoPIIInputGuardrail.new)
agent.add_output_guardrail(NoURLOutputGuardrail.new)
ask(agent, "What are the key features of Ruby?")

# Case 2: Input guardrail violation — My Number (12-digit number) in the input.
puts
puts "[Case 2 - Input Guardrail]"
agent = SafeQAAgent.new
agent.add_input_guardrail(NoPIIInputGuardrail.new)
agent.add_output_guardrail(NoURLOutputGuardrail.new)
ask(agent, "Please check the application status for 123456789012.")

# Case 3: Output guardrail — asks for a URL. NOTE: depending on the LLM's
# response this case may not always trigger the guardrail.
puts
puts "[Case 3 - Output Guardrail]"
agent = SafeQAAgent.new
agent.add_input_guardrail(NoPIIInputGuardrail.new)
agent.add_output_guardrail(NoURLOutputGuardrail.new)
ask(agent, "Tell me the official Ruby website URL starting with https://.")
