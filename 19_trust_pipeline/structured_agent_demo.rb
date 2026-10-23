#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../shared/llm_config"
require "phronomy"

class InvoiceExtractionAgent < Phronomy::Agent::Base
  agent_definition id: "example-19-invoice-extraction", version: 1
  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  instructions "Extract the invoice identifier and total from the supplied text. " \
    "Copy the identifier exactly, preserving every character and leading zero. Do not normalize or invent values."
end

INVOICE_SCHEMA = {
  type: "object",
  properties: {
    invoice_id: {type: "string"},
    total: {type: "number", minimum: 0}
  },
  required: ["invoice_id", "total"],
  additionalProperties: false
}.freeze

begin
  result = Phronomy::Agent.open_scope do |scope|
    agent = scope.create(InvoiceExtractionAgent)
    agent.invoke_async(
      "Invoice INV-2026-001. Total: 1250.",
      output_schema: INVOICE_SCHEMA
    )
  end
  invoice = result.fetch(:output)
  # This fixed example has an independent acceptance oracle. Schema validity
  # alone cannot establish faithful extraction of business facts.
  expected = {"invoice_id" => "INV-2026-001", "total" => 1250}
  unless invoice == expected
    warn "Invoice fidelity failed: expected #{expected.inspect}; received #{invoice.inspect}"
    exit 1
  end
  puts "Invoice: #{invoice.fetch("invoice_id")}"
  puts "Total: #{invoice.fetch("total")}"
rescue Phronomy::Agent::OutputError => error
  warn "No valid structured result: #{error.code} / #{error.reason}"
  exit 1
rescue Phronomy::Agent::ScopeCleanupError => error
  warn "Agent cleanup failed: #{error.failures.length}"
  warn "Primary error: #{error.primary_error.message}" if error.primary_error
  # The supervisor may retry error.scope.release! after the cause is resolved.
  # This one-shot example does not cancel or retry an unknown operation.
  raise
end
