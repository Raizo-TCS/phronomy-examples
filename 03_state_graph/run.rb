#!/usr/bin/env ruby
# frozen_string_literal: true

# 03 Workflow with Conditional Routing
#
# Demonstrates a self-improving loop using Phronomy::Workflow with conditional
# event routing. The workflow evaluates a piece of text, and if its quality
# score is below the threshold (and the iteration cap has not been reached),
# it rewrites the text and re-evaluates.
#
# Each Agent call is started in an entry action. Agent#invoke_async returns a
# Task; Task completion is converted into a Workflow event. Transition actions
# apply the Agent result to the context.

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

def event_payload!(event)
  payload = event.payload || {}
  raise payload[:error] if payload[:error]
  payload
end

# workflow is captured by reference in the Task completion callbacks.
workflow = nil
workflow = Phronomy::Workflow.define(MyState) do
  initial :evaluate

  state :evaluate
  entry :evaluate, ->(state) {
    workflow_instance_id = state.workflow_instance_id
    iterations = state.iterations
    prompt = "Rate the quality of the following text on a scale of 0 to 10.\n\n#{state.text}"

    agent = EvaluatorAgent.new
    task = agent.invoke_async(prompt).map do |result|
      score = result.fetch(:output).scan(/\d+/).first.to_i.clamp(0, 10)
      puts "[Iteration #{iterations}] Score: #{score}"
      {score: score}
    end

    task.on_complete do |payload, error|
      workflow.signal(
        workflow_instance_id: workflow_instance_id,
        event: :evaluation_completed,
        payload: error ? {error: error} : payload
      )
    end

    state
  }

  state :improve
  entry :improve, ->(state) {
    workflow_instance_id = state.workflow_instance_id
    iterations = state.iterations

    agent = ImproverAgent.new
    task = agent.invoke_async(state.text).map do |result|
      {
        text: result.fetch(:output).strip,
        iterations: iterations + 1
      }
    end

    task.on_complete do |payload, error|
      workflow.signal(
        workflow_instance_id: workflow_instance_id,
        event: :improvement_completed,
        payload: error ? {error: error} : payload
      )
    end

    state
  }

  # Finish if score is good enough or iteration cap reached; apply score.
  transition(
    from: :evaluate,
    on: :evaluation_completed,
    to: :__finish__,
    guard: ->(ctx, event) {
      payload = event_payload!(event)
      payload.fetch(:score) >= 7 || ctx.iterations >= 3
    },
    action: ->(ctx, event) {
      score = event_payload!(event).fetch(:score)
      puts "[Done] Final score: #{score}"
      ctx.merge(score: score)
    }
  )

  # Otherwise move to :improve; apply new score.
  transition(
    from: :evaluate,
    on: :evaluation_completed,
    to: :improve,
    action: ->(ctx, event) {
      ctx.merge(score: event_payload!(event).fetch(:score))
    }
  )

  # After improvement, re-evaluate with updated text and iteration count.
  transition(
    from: :improve,
    on: :improvement_completed,
    to: :evaluate,
    action: ->(ctx, event) {
      payload = event_payload!(event)
      ctx.merge(
        text: payload.fetch(:text),
        iterations: payload.fetch(:iterations)
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
