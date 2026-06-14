#!/usr/bin/env ruby
# frozen_string_literal: true

# 28 Filter — input, output, and tool result filtering
#
# Demonstrates Phronomy::Filter::Base for transforming or blocking values at
# three agent boundaries:
#
#   - input_filter   — applied to user input before the LLM is called
#   - output_filter  — applied to the final LLM output before it is returned
#   - add_tool_result_filter — applied to a specific tool's return value
#
# The same filter class can be reused at any combination of sites.
# Guardrail subclasses (Phronomy::Guardrail::InputGuardrail etc.) can be passed
# directly to add_input_filter / add_output_filter since they implement #call.

require_relative "../shared/llm_config"
require_relative "../shared/output_validator"
require "phronomy"

# ---------------------------------------------------------------------------
# Filters
# ---------------------------------------------------------------------------

# Masks common PII patterns in any string value.
class PiiMaskFilter < Phronomy::Filter::Base
  PHONE_RE  = /\b\d{2,4}-\d{2,4}-\d{4}\b/
  CARD_RE   = /\b(?:\d{4}[- ]?){3}\d{4}\b/
  EMAIL_RE  = /\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b/

  def call(value, **_context)
    value.to_s
         .gsub(CARD_RE,  "[CARD]")
         .gsub(PHONE_RE, "[PHONE]")
         .gsub(EMAIL_RE, "[EMAIL]")
  end
end

# Blocks values that contain the word "secret".
class NoSecretFilter < Phronomy::Filter::Base
  def call(value, **_context)
    block!("Value contains forbidden word 'secret'") if value.to_s.include?("secret")
    value
  end
end

# ---------------------------------------------------------------------------
# Tool that returns raw customer data (simulated)
# ---------------------------------------------------------------------------

class CustomerLookupTool < Phronomy::Agent::Context::Capability::Base
  description "Look up a customer record by ID and return their contact details."
  param :customer_id, type: :string, desc: "The customer identifier."

  def execute(customer_id:)
    # Simulated database response — contains PII.
    "Customer #{customer_id}: email=alice@example.com phone=090-1234-5678 card=4111-1111-1111-1111"
  end
end

# ---------------------------------------------------------------------------
# Agent
# ---------------------------------------------------------------------------

class CustomerAgent < Phronomy::Agent::Base
  model        LLMConfig::MODEL
  provider     LLMConfig::PROVIDER
  instructions "You are a customer support assistant. Use the customer_lookup tool to find customer details."
  tools        CustomerLookupTool
end

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

puts "=== 28 Filter Example ===\n\n"

# ── Scenario 1: input filter masks PII — shown without a real LLM call ─────
puts "--- Scenario 1: input filter (PII masking in user input) ---"

# Show the filter transforming the raw input directly.
raw_input = "My card is 4111-1111-1111-1111 and phone is 090-1234-5678, please help."
masked_input = PiiMaskFilter.new.call(raw_input)
puts "Original input: #{raw_input}"
puts "After filter:   #{masked_input}"

OutputValidator.validate(
  "PiiMaskFilter masks card and phone in input",
  check: ->(_) {
    !masked_input.include?("4111") &&
      !masked_input.include?("090-1234") &&
      masked_input.include?("[CARD]") &&
      masked_input.include?("[PHONE]")
  }
) { [1] }
puts

# ── Scenario 2: tool result filter masks PII from tool output ──────────────
puts "--- Scenario 2: tool result filter (PII masking in tool return value) ---"

agent2 = CustomerAgent.new
agent2.add_tool_result_filter(CustomerLookupTool, PiiMaskFilter.new)

# Verify the filter is applied by inspecting the wrapped call directly.
wrapped = agent2.send(:prepare_tool_class, CustomerLookupTool)
raw_result = CustomerLookupTool.new.call({customer_id: "C001"})
filtered_result = wrapped.new.call({customer_id: "C001"})

puts "Raw tool output:      #{raw_result}"
puts "Filtered tool output: #{filtered_result}"

OutputValidator.validate(
  "tool result has PII masked",
  check: ->(_) {
    !filtered_result.include?("alice@example.com") &&
      !filtered_result.include?("090-1234-5678") &&
      !filtered_result.include?("4111-1111-1111-1111") &&
      filtered_result.include?("[EMAIL]")
  }
) { [1] }
puts

# ── Scenario 3: blocking filter rejects forbidden content ──────────────────
puts "--- Scenario 3: blocking filter (NoSecretFilter) ---"

agent3 = CustomerAgent.new
agent3.add_input_filter(NoSecretFilter.new)

begin
  agent3.invoke("Tell me the secret password.")
  puts "ERROR: expected FilterBlockError was not raised"
rescue Phronomy::FilterBlockError => e
  puts "Blocked as expected: #{e.message}"
end
puts

# ── Scenario 4: same filter instance reused on input and output ───────────
puts "--- Scenario 4: same PiiMaskFilter on input and output ---"

agent4 = CustomerAgent.new
f = PiiMaskFilter.new
agent4.add_input_filter(f)
agent4.add_output_filter(f)

puts "PiiMaskFilter registered at both input and output boundaries."
puts "Any PII in user input or in the LLM's final answer will be masked."
puts

# ── Scenario 5: class-level DSL ────────────────────────────────────────────
puts "--- Scenario 5: class-level filter DSL ---"

# Filters declared inside the class body apply to every instance.
class SecureCustomerAgent < Phronomy::Agent::Base
  model        LLMConfig::MODEL
  provider     LLMConfig::PROVIDER
  instructions "You are a secure customer support assistant."
  tools        CustomerLookupTool

  # Pass the class — phronomy calls .new automatically at registration time.
  # Each registration site gets an independent instance.
  input_filter       PiiMaskFilter
  output_filter      PiiMaskFilter
  tool_result_filter PiiMaskFilter
end

# Verify: the class-level tool_result_filter is applied without any
# instance-level registration.
wrapped_class = SecureCustomerAgent.new.send(:prepare_tool_class, CustomerLookupTool)
class_filtered = wrapped_class.new.call({customer_id: "C002"})

puts "SecureCustomerAgent tool result: #{class_filtered}"

OutputValidator.validate(
  "class-level tool_result_filter masks PII automatically",
  check: ->(_) {
    !class_filtered.include?("alice@example.com") &&
      class_filtered.include?("[EMAIL]")
  }
) { [1] }

puts "Class-level input_filter and output_filter will mask PII on every invoke."
puts

puts "Done."
