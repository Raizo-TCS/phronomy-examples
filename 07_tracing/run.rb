#!/usr/bin/env ruby
# frozen_string_literal: true

# 07 Tracing
#
# Demonstrates plugging a custom tracer into phronomy via configuration.
# ConsoleTracer prints span start/end events with elapsed time.

require_relative "../shared/llm_config"
require_relative "../shared/output_validator"
require "phronomy"
require_relative "tracer"
require_relative "llm_compatibility"

single_attempt = TracingLLMCompatibility.configure!(
  mode: ENV.fetch("PHRONOMY_TRACING_LLM_MODE", "native"),
  model: LLMConfig::MODEL, provider: LLMConfig::PROVIDER, base_url: LLMConfig::BASE_URL
)

Phronomy.configure do |c|
  c.tracer = ConsoleTracer.new
end

class CodeState
  include Phronomy::WorkflowContext

  field :language, type: :replace, default: ""
  field :output,   type: :replace, default: ""
end

# Agent::Base routes LLM calls through phronomy's pipeline, so spans are
# emitted automatically via the configured tracer — no manual trace block needed.
class CodeGeneratorAgent < Phronomy::Agent::Base
  agent_definition id: "example-07-code-generator-agent", version: 1

  model        LLMConfig::MODEL
  provider     LLMConfig::PROVIDER
  instructions "You are a programming expert."
end

Phronomy::Agent.open_scope do |agents|
  app = Phronomy::Workflow.define(CodeState) do
    initial :generate

    task_state :generate,
      start: ->(state) {
        agents.create_async(CodeGeneratorAgent).flat_map do |agent|
          agent.invoke_async("Write a Hello World program in #{state.language}. Return code only.")
        end
      },
      apply: ->(state, result) { state.merge(output: result.fetch(:output)) }

    state :done
    transition from: :generate, to: :done
    transition from: :done, to: :__finish__
  end

  puts "=== Tracing Example ==="
  puts
  check = ->(r) { r.output.length >= 20 && r.output.match?(/[\w(){}]/) }
  generate = -> { app.invoke({language: "Go"}) }
  result = if single_attempt
    generate.call.tap do |response|
      raise "Go code output validation failed (single attempt; no retry)" unless check.call(response)
    end
  else
    OutputValidator.validate("Go Hello World code generated with tracing", check: check, &generate)
  end
  puts
  puts "--- LLM Response ---"
  puts result.output
end
