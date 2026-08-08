#!/usr/bin/env ruby
# frozen_string_literal: true

# 01 Basic Workflow Pipeline
#
# Demonstrates a simple single-node pipeline using Phronomy::Workflow:
#   :generate → :done → finish
#
# The entry action starts an async Agent call and signals the Workflow when
# the result is ready. The transition action copies the Agent output into the
# context before the :done entry runs.
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

# workflow is assigned after Workflow.define so the closure captures it by
# reference and can call workflow.signal when the Agent completes.
app = nil
app = Phronomy::Workflow.define(CodeState) do
  initial :generate

  state :generate
  state :done

  entry :generate, ->(state) {
    thread_id = state.thread_id
    language  = state.language
    CodeGeneratorAgent.new.invoke_async(
      "Write a Hello World program in #{language}. Return code only.",
      on_event: ->(event) {
        next unless event.type == :done
        app.signal(
          thread_id: thread_id,
          event: :generation_completed,
          payload: {output: event.payload[:output]}
        )
      }
    )
    state
  }

  transition(
    from: :generate,
    on: :generation_completed,
    to: :done,
    action: ->(ctx, event) { ctx.merge(output: event.payload[:output]) }
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
