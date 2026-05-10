#!/usr/bin/env ruby
# frozen_string_literal: true

# 01 Basic Graph Pipeline
#
# Demonstrates a simple two-node pipeline using StateGraph:
#   :render_prompt -> :generate_code
#
# The same graph is reused across multiple inputs to show that the
# pipeline is stateless and reusable.

require_relative "../shared/llm_config"
require "phronomy"

class CodeState
  include Phronomy::Graph::State

  field :language, type: :replace, default: ""
  field :output,   type: :replace, default: ""
end

graph = Phronomy::Graph::StateGraph.new(CodeState)

graph.add_node(:generate) do |state|
  chat = RubyLLM.chat(model: LLMConfig::MODEL, provider: LLMConfig::PROVIDER, assume_model_exists: true)
  chat.with_instructions("You are a programming expert.")
  response = chat.ask("Write a Hello World program in #{state.language}. Return code only.")
  state.merge(output: response.content)
end

graph.set_entry_point(:generate)
graph.add_edge(:generate, Phronomy::Graph::StateGraph::FINISH)

app = graph.compile

puts "=== Basic Graph Pipeline Example ==="

%w[Ruby Python JavaScript].each do |language|
  puts
  puts "Language: #{language}"
  puts "--- Response ---"
  result = app.invoke({language: language})
  puts result.output
end
