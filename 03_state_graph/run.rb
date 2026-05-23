#!/usr/bin/env ruby
# frozen_string_literal: true

# 03 Workflow with Conditional Routing
#
# Demonstrates a self-improving loop using Phronomy::Workflow with conditional
# event routing. The workflow evaluates a piece of text, and if its quality
# score is below the threshold (and the iteration cap has not been reached),
# it rewrites the text and re-evaluates.

require_relative "../shared/llm_config"
require "phronomy"

class MyState
  include Phronomy::WorkflowContext

  field :text,       type: :replace, default: ""
  field :score,      type: :replace, default: 0
  field :iterations, type: :replace, default: 0
end

llm = lambda do |input|
  chat = RubyLLM.chat(model: LLMConfig::MODEL, provider: LLMConfig::PROVIDER, assume_model_exists: true)
  chat.with_instructions(input[:system]) if input[:system]
  chat.ask(input[:user]).content
end

EVALUATE_NODE = ->(state) {
  response = llm.call({
    system: "You are a strict text evaluator. Return only an integer score from 0 to 10. No explanation.",
    user:   "Rate the quality of the following text on a scale of 0 to 10.\n\n#{state.text}"
  })
  score = response.scan(/\d+/).first.to_i.clamp(0, 10)
  puts "[Iteration #{state.iterations}] Score: #{score}"
  state.score = score
}

IMPROVE_NODE = ->(state) {
  improved = llm.call({
    system: "You are a professional copywriter. Rewrite the given text to be more compelling. Return only the rewritten text.",
    user:   state.text
  })
  state.text       = improved.strip
  state.iterations = state.iterations + 1
}

FINISH_NODE = ->(state) {
  puts "[Done] Final score: #{state.score}"
  state
}

app = Phronomy::Workflow.define(MyState) do
  initial :evaluate
  state :evaluate, action: EVALUATE_NODE
  state :improve,  action: IMPROVE_NODE
  state :finish,   action: FINISH_NODE

  transition from: :evaluate, guard: ->(s) { s.score >= 7 || s.iterations >= 3 }, to: :finish
  transition from: :evaluate, to: :improve
  transition from: :improve, to: :evaluate
  transition from: :finish, to: :__finish__
end

puts "=== Workflow Conditional Routing Example ==="
initial_text = "Ruby is ok."
puts "Initial text: #{initial_text.inspect}"
puts

final = app.invoke({text: initial_text, score: 0, iterations: 0})

puts
puts "Final text:"
puts final.text
