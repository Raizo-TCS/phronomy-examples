#!/usr/bin/env ruby
# frozen_string_literal: true

# 01 Basic Workflow Pipeline
#
# Demonstrates a simple single-node pipeline using Phronomy::Workflow:
#   :generate
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
  model        LLMConfig::MODEL
  provider     LLMConfig::PROVIDER
  instructions "You are a programming expert."
end

GENERATE_NODE = ->(state) {
  CodeGeneratorAgent.new.invoke_async(
    "Write a Hello World program in #{state.language}. Return code only."
  ).map { |result| state.merge(output: result[:output]) }
}

app = Phronomy::Workflow.define(CodeState) do
  initial :generate
  state :generate, action: GENERATE_NODE
  transition from: :generate, to: :__finish__
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
