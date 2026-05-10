#!/usr/bin/env ruby
# frozen_string_literal: true

# 03 State Graph
#
# Demonstrates a self-improving loop using a StateGraph with conditional
# edges. The graph evaluates a piece of text, and if its quality score is
# below the threshold (and the iteration cap has not been reached), it
# rewrites the text and re-evaluates.

require_relative "../shared/llm_config"
require "phronomy"

class MyState
  include Phronomy::Graph::State

  field :text,       type: :replace, default: ""
  field :score,      type: :replace, default: 0
  field :iterations, type: :replace, default: 0
end

llm = lambda do |input|
  chat = RubyLLM.chat(model: LLMConfig::MODEL, provider: LLMConfig::PROVIDER, assume_model_exists: true)
  chat.with_instructions(input[:system]) if input[:system]
  chat.ask(input[:user]).content
end

graph = Phronomy::Graph::StateGraph.new(MyState)

graph.add_node(:evaluate) do |state|
  response = llm.call({
    system: "You are a strict text evaluator. Return only an integer score from 0 to 10. No explanation.",
    user:   "Rate the quality of the following text on a scale of 0 to 10.\n\n#{state.text}"
  })
  score = response.scan(/\d+/).first.to_i.clamp(0, 10)
  puts "[Iteration #{state.iterations}] Score: #{score}"
  state.merge(score: score)
end

graph.add_node(:improve) do |state|
  improved = llm.call({
    system: "You are a professional copywriter. Rewrite the given text to be more compelling. Return only the rewritten text.",
    user:   state.text
  })
  state.merge(text: improved.strip, iterations: state.iterations + 1)
end

graph.add_node(:finish) do |state|
  puts "[Done] Final score: #{state.score}"
  state
end

graph.set_entry_point(:evaluate)
graph.add_conditional_edges(
  :evaluate,
  ->(state) { state.score >= 7 || state.iterations >= 3 },
  {true => :finish, false => :improve}
)
graph.add_edge(:improve, :evaluate)
graph.add_edge(:finish, Phronomy::Graph::StateGraph::FINISH)

compiled = graph.compile

puts "=== State Graph Example ==="
initial_text = "Ruby is ok."
puts "Initial text: #{initial_text.inspect}"
puts

final = compiled.invoke({text: initial_text, score: 0, iterations: 0})

puts
puts "Final text:"
puts final.text
