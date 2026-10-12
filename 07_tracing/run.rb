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

app = Phronomy::Workflow.define(CodeState) do
  initial :generate

  task_state :generate,
    start: ->(state) {
      CodeGeneratorAgent.new.invoke_async(
        "Write a Hello World program in #{state.language}. Return code only."
      )
    },
    apply: ->(state, result) { state.merge(output: result.fetch(:output)) }

  state :done
  transition from: :generate, to: :done
  transition from: :done, to: :__finish__
end

puts "=== Tracing Example ==="
puts
result = OutputValidator.validate(
  "Go Hello World code generated with tracing",
  check: ->(r) { r.output.length >= 20 && r.output.match?(/[\w(){}]/) }
) { app.invoke({language: "Go"}) }
puts
puts "--- LLM Response ---"
puts result.output
