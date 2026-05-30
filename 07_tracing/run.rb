#!/usr/bin/env ruby
# frozen_string_literal: true

# 07 Tracing
#
# Demonstrates plugging a custom tracer into phronomy via configuration.
# ConsoleTracer prints span start/end events with elapsed time.

require_relative "../shared/llm_config"
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

GENERATE_NODE_WITH_TRACE = ->(state) {
  Phronomy.configuration.tracer.trace(:generate, input: state) do
    chat = RubyLLM.chat(model: LLMConfig::MODEL, **(LLMConfig::PROVIDER ? { provider: LLMConfig::PROVIDER, assume_model_exists: true } : {}))
    chat.with_instructions("You are a programming expert.")
    response = chat.ask("Write a Hello World program in #{state.language}. Return code only.")
    state.merge(output: response.content)
  end
}

app = Phronomy::Workflow.define(CodeState) do
  initial :generate
  state :generate, action: GENERATE_NODE_WITH_TRACE
  transition from: :generate, to: :__finish__
end

puts "=== Tracing Example ==="
puts
result = app.invoke({language: "Go"})
puts
puts "--- LLM Response ---"
puts result.output
