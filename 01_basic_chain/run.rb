#!/usr/bin/env ruby
# frozen_string_literal: true

# 01 Basic Workflow Pipeline
#
# Demonstrates a simple single-node pipeline using Phronomy::Workflow:
#   :generate → :done → finish
#
# The entry action starts an async Agent call. Agent#invoke_async returns a
# Phronomy::Task; Task completion is converted into an explicit Workflow event.
# The transition action copies the Agent output into the context before the
# :done entry runs.
#
# The same workflow is reused across multiple inputs to show that the
# pipeline is stateless and reusable.

require_relative "../shared/llm_config"
require_relative "../shared/output_validator"
require "phronomy"

class CodeState
  include Phronomy::WorkflowContext

  field :language, type: :replace, default: ""
  field :output,   type: :replace, default: ""
end

class CodeGeneratorAgent < Phronomy::Agent::Base
  agent_definition id: "example-01-code-generator-agent", version: 1

  model        LLMConfig::MODEL
  provider     LLMConfig::PROVIDER
  instructions "You are a programming expert."
end

def event_payload!(event)
  payload = event.payload || {}
  raise payload[:error] if payload[:error]
  payload
end

# app is assigned after Workflow.define so the completion callback captures it
# by reference and can call app.signal when the Agent Task settles.
app = nil
app = Phronomy::Workflow.define(CodeState) do
  initial :generate

  state :generate
  state :done

  entry :generate, ->(state) {
    workflow_instance_id = state.workflow_instance_id
    prompt = "Write a Hello World program in #{state.language}. Return code only."

    agent = CodeGeneratorAgent.new
    task = agent.invoke_async(prompt).map do |result|
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

puts "=== Basic Workflow Pipeline Example ==="

%w[Ruby Python JavaScript].each do |language|
  puts
  puts "Language: #{language}"
  puts "--- Response ---"
  result = OutputValidator.validate(
    "#{language} Hello World code generated",
    check: ->(r) { r.output.length >= 20 && r.output.match?(/[\w(){}]/) }
  ) { app.invoke({language: language}) }
  puts result.output
end
