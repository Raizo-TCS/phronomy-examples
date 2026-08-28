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

def event_payload!(event)
  payload = event.payload || {}
  raise payload[:error] if payload[:error]
  payload
end

app = nil  # declared first so the Task completion callback can capture it by reference

GENERATE_NODE_WITH_TRACE = ->(state) {
  workflow_instance_id = state.workflow_instance_id
  language = state.language

  agent = CodeGeneratorAgent.new
  task = agent.invoke_async(
    "Write a Hello World program in #{language}. Return code only."
  ).map do |result|
    {output: result.fetch(:output)}
  end

  task.on_complete do |payload, error|
    app.signal(
      workflow_instance_id: workflow_instance_id,
      event: :generation_completed,
      payload: error ? {error: error} : payload
    )
  end

  state
}

app = Phronomy::Workflow.define(CodeState) do
  initial :generate
  state :generate
  state :done

  entry :generate, GENERATE_NODE_WITH_TRACE

  transition(
    from: :generate,
    on: :generation_completed,
    to: :done,
    action: ->(ctx, event) {
      ctx.merge(output: event_payload!(event).fetch(:output))
    }
  )
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
