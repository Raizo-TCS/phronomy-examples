#!/usr/bin/env ruby
# frozen_string_literal: true

# 28 Filters
#
# Demonstrates current public Filter boundaries:
# - input
# - output
# - tool result
# - class DSL and per-instance registration
#
# No private Agent preparation APIs are used.

require_relative "../shared/llm_config"
require_relative "../shared/output_validator"
require "phronomy"

class PiiMaskFilter < Phronomy::Filter::Base
  EMAIL = /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/i

  def call(value, **)
    value.to_s.gsub(EMAIL, "[EMAIL REDACTED]")
  end
end

class SecretBlockingFilter < Phronomy::Filter::Base
  def call(value, **)
    block!("secret marker detected") if value.to_s.include?("TOP-SECRET")
    value
  end
end

class CustomerLookupTool < Phronomy::Tool::Base
  description "Look up the example customer record."
  param :customer_id, type: :string, desc: "Customer id"

  def execute(customer_id:)
    "customer=#{customer_id}; email=alice@example.test; tier=gold"
  end
end

class CustomerAgent < Phronomy::Agent::Base
  agent_definition id: "example-28-customer-agent", version: 2

  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  instructions <<~PROMPT
    You are a customer-support assistant.
    When asked about a customer record, MUST call customer_lookup.
    Report only the information returned by the tool.
  PROMPT

  tools(CustomerLookupTool => "customer_lookup")
end

puts "=== 28 Filters ==="
puts

puts "--- 1. A Filter is independently testable ---"
mask = PiiMaskFilter.new
puts mask.call("Contact alice@example.test for help.")
puts

puts "--- 2. Per-instance input Filter can block before the LLM ---"
blocked_agent = CustomerAgent.new
blocked_agent.add_input_filter(SecretBlockingFilter.new)

begin
  blocked_agent.invoke("TOP-SECRET: look up customer 42")
rescue Phronomy::FilterBlockError => e
  puts "Blocked: #{e.message}"
end
puts

puts "--- 3. Tool-result Filter transforms data at the capability boundary ---"
tool_events = []
tool_filtered_agent = CustomerAgent.new(
  on_event: ->(event) { tool_events << event }
)
tool_filtered_agent.add_tool_result_filter(
  CustomerLookupTool,
  PiiMaskFilter.new
)
tool_result = OutputValidator.validate(
  "tool result passes through the scoped Filter",
  check: lambda { |_r|
    tool_events.any? { |event|
      event.type == :tool_result &&
        event.payload[:tool_name] == "customer_lookup" &&
        event.payload[:tool_result].to_s.include?("[EMAIL REDACTED]")
    }
  }
) do
  tool_filtered_agent.invoke(
    "Look up customer 42. You MUST use customer_lookup and report the result."
  )
end

filtered_event = tool_events.find do |event|
  event.type == :tool_result &&
    event.payload[:tool_name] == "customer_lookup"
end

puts "Filtered tool result: #{filtered_event.payload[:tool_result]}"
puts "Final Agent output:   #{tool_result[:output]}"
puts

puts "--- 4. Class-level Filters define a reusable policy ---"

class SafeCustomerAgent < Phronomy::Agent::Base
  agent_definition id: "example-28-safe-customer-agent", version: 1

  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  instructions <<~PROMPT
    When asked about a customer record, MUST call customer_lookup.
    Report only the tool result.
  PROMPT

  tools(CustomerLookupTool => "customer_lookup")
  input_filter SecretBlockingFilter.new
  output_filter PiiMaskFilter.new
  tool_result_filter PiiMaskFilter.new
end

safe_events = []
safe_agent = SafeCustomerAgent.new(
  on_event: ->(event) { safe_events << event }
)
safe_result = OutputValidator.validate(
  "class-level Filters protect tool and output boundaries",
  check: lambda { |r|
    r[:output].to_s.include?("[EMAIL REDACTED]") &&
      safe_events.any? { |event|
        event.type == :tool_result &&
          event.payload[:tool_result].to_s.include?("[EMAIL REDACTED]")
      }
  }
) do
  safe_agent.invoke("Look up customer 99. You MUST use customer_lookup.")
end

safe_tool_event = safe_events.find { |event| event.type == :tool_result }

puts "Tool result: #{safe_tool_event.payload[:tool_result]}"
puts "Output:      #{safe_result[:output]}"
