#!/usr/bin/env ruby
# frozen_string_literal: true

# 03 Workflow with Conditional Routing
#
# Demonstrates a self-improving loop using Phronomy::Workflow with conditional
# routing. The workflow evaluates a piece of text, and if its quality
# score is below the threshold (and the iteration cap has not been reached),
# it rewrites the text and re-evaluates.
#
# Each task_state starts an Agent call and applies its successful result.
# Ordinary guards then choose the next state using the updated context.

require_relative "../shared/llm_config"
require_relative "../shared/output_validator"
require "phronomy"

class MyState
  include Phronomy::WorkflowContext

  field :text,       type: :replace, default: ""
  field :score,      type: :replace, default: 0
  field :iterations, type: :replace, default: 0
end

class EvaluatorAgent < Phronomy::Agent::Base
  agent_definition id: "example-03-evaluator-agent", version: 1

  model        LLMConfig::MODEL
  provider     LLMConfig::PROVIDER
  instructions "You are a strict text evaluator. Return only an integer score from 0 to 10. No explanation."
end

class ImproverAgent < Phronomy::Agent::Base
  agent_definition id: "example-03-improver-agent", version: 1

  model        LLMConfig::MODEL
  provider     LLMConfig::PROVIDER
  instructions "You are a professional copywriter. Rewrite the given text to be more compelling. Return only the rewritten text."
end

Phronomy::Agent.open_scope do |agents|
  workflow = Phronomy::Workflow.define(MyState) do
    initial :evaluate

    task_state :evaluate,
      start: ->(state) {
        prompt = "Rate the quality of the following text on a scale of 0 to 10.\n\n#{state.text}"
        agents.create_async(EvaluatorAgent).flat_map { |agent| agent.invoke_async(prompt) }
      },
      apply: ->(state, result) {
        score = result.fetch(:output).scan(/\d+/).first.to_i.clamp(0, 10)
        puts "[Iteration #{state.iterations}] Score: #{score}"
        state.merge(score: score)
      }

    task_state :improve,
      start: ->(state) { agents.create_async(ImproverAgent).flat_map { |agent| agent.invoke_async(state.text) } },
      apply: ->(state, result) {
        state.merge(text: result.fetch(:output).strip, iterations: state.iterations + 1)
      }

    # Guards see the score already applied by the task state.
    transition from: :evaluate, to: :__finish__,
      guard: ->(state) { state.score >= 7 || state.iterations >= 3 },
      action: ->(state) { puts "[Done] Final score: #{state.score}"; state }
    transition from: :evaluate, to: :improve
    transition from: :improve, to: :evaluate
  end

  puts "=== Workflow Conditional Routing Example ==="
  initial_text = "Ruby is ok."
  puts "Initial text: #{initial_text.inspect}"
  puts

  final = OutputValidator.validate(
    "improved text longer than original",
    check: ->(r) { r.text.length > initial_text.length && r.score >= 0 }
  ) { workflow.invoke({text: initial_text, score: 0, iterations: 0}) }

  puts
  puts "Final text:"
  puts final.text
end
