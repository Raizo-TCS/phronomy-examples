#!/usr/bin/env ruby
# frozen_string_literal: true

# 03 Workflow with Conditional Routing
#
# Demonstrates a self-improving loop using Phronomy::Workflow with conditional
# event routing. The workflow evaluates a piece of text, and if its quality
# score is below the threshold (and the iteration cap has not been reached),
# it rewrites the text and re-evaluates.
#
# Each Agent call is started in an entry action and signals a Workflow event
# when done. The transition actions apply the Agent result to the context.

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

# workflow is captured by reference in the on_event lambdas.
workflow = nil
workflow = Phronomy::Workflow.define(MyState) do
  initial :evaluate

  # :evaluate — active state: entry starts the LLM call and returns immediately.
  state :evaluate
  entry :evaluate, ->(state) {
    thread_id  = state.thread_id
    text       = state.text
    iterations = state.iterations

    EvaluatorAgent.new.invoke_async(
      "Rate the quality of the following text on a scale of 0 to 10.\n\n#{text}",
      on_event: ->(event) {
        next unless event.type == :done
        score = event.payload[:output].scan(/\d+/).first.to_i.clamp(0, 10)
        puts "[Iteration #{iterations}] Score: #{score}"
        workflow.signal(
          thread_id: thread_id,
          event: :evaluation_completed,
          payload: {score: score}
        )
      }
    )
    state
  }

  # :improve — active state: entry starts the rewrite and returns immediately.
  state :improve
  entry :improve, ->(state) {
    thread_id  = state.thread_id
    text       = state.text
    iterations = state.iterations

    ImproverAgent.new.invoke_async(
      text,
      on_event: ->(event) {
        next unless event.type == :done
        workflow.signal(
          thread_id: thread_id,
          event: :improvement_completed,
          payload: {
            text:       event.payload[:output].strip,
            iterations: iterations + 1
          }
        )
      }
    )
    state
  }

  # Finish if score is good enough or iteration cap reached; apply score.
  transition(
    from: :evaluate,
    on: :evaluation_completed,
    to: :__finish__,
    guard: ->(ctx, event) {
      event.payload[:score] >= 7 || ctx.iterations >= 3
    },
    action: ->(ctx, event) {
      puts "[Done] Final score: #{event.payload[:score]}"
      ctx.merge(score: event.payload[:score])
    }
  )

  # Otherwise move to :improve; apply new score.
  transition(
    from: :evaluate,
    on: :evaluation_completed,
    to: :improve,
    action: ->(ctx, event) { ctx.merge(score: event.payload[:score]) }
  )

  # After improvement, re-evaluate with updated text and iteration count.
  transition(
    from: :improve,
    on: :improvement_completed,
    to: :evaluate,
    action: ->(ctx, event) {
      ctx.merge(
        text:       event.payload[:text],
        iterations: event.payload[:iterations]
      )
    }
  )
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
