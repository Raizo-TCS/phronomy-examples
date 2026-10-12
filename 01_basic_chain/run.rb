#!/usr/bin/env ruby
# frozen_string_literal: true

# 01 Basic Workflow Pipeline
#
# Demonstrates a simple single-node pipeline using Phronomy::Workflow:
#   :generate → :done → finish
#
# task_state starts an asynchronous Agent call and applies its successful
# result before transition guards and the next state's entry actions run.
# Phronomy owns completion correlation, failure propagation and stale results.
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

app = Phronomy::Workflow.define(CodeState) do
  initial :generate

  task_state :generate,
    start: ->(state) {
      prompt = "Write a Hello World program in #{state.language}. Return code only."
      CodeGeneratorAgent.new.invoke_async(prompt)
    },
    apply: ->(state, result) { state.merge(output: result.fetch(:output)) }

  state :done
  transition from: :generate, to: :done
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
