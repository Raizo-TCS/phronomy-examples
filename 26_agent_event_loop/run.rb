#!/usr/bin/env ruby
# frozen_string_literal: true

# 26 Agent async events + Workflow coordination
#
# Shows the public bridge between Agent execution and Workflow state:
#
#   Agent#invoke_async
#       -> structured lifecycle event on Runtime EventLoop
#       -> Workflow#signal
#       -> FSM transition
#
# Also demonstrates explicit Workflow-instance correlation and timeout classification.

require_relative "../shared/llm_config"
require_relative "../shared/output_validator"
require "phronomy"

class TranslationAgent < Phronomy::Agent::Base
  agent_definition id: "example-26-translation-agent", version: 2

  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  instructions "Translate the user's text to Japanese. Return only the translation."
end

puts "=== 26 Agent async events + Workflow coordination ==="
puts

puts "--- Pattern 1: invoke_async lifecycle event + Task result ---"

events = []
agent = TranslationAgent.new(
  on_event: lambda { |event|
    events << event.type
    puts "Agent event: #{event.type}"
  }
)
task = agent.invoke_async("Good morning.")

direct_result = OutputValidator.validate(
  "invoke_async returns a translated answer",
  check: ->(r) { r[:output].to_s.length >= 2 }
) { task.wait_result }

puts "Output:       #{direct_result[:output]}"
puts "Execution id: #{direct_result[:execution_id]}"
puts "Journal pos.:  #{direct_result[:journal_position]}"
puts "Events:       #{events.inspect}"
puts

puts "--- Pattern 2: Agent completion signals a Workflow ---"

class TranslationState
  include Phronomy::WorkflowContext

  field :query, type: :replace, default: ""
  field :answer, type: :replace, default: ""
  field :execution_id, type: :replace, default: ""
  field :journal_position, type: :replace, default: 0
end

translation_workflow = nil
translation_workflow = Phronomy::Workflow.define(TranslationState) do
  initial :translating

  state :translating
  entry :translating, lambda { |ctx|
    workflow_instance_id = ctx.workflow_instance_id

    agent = TranslationAgent.new(
      on_event: lambda { |event|
        next unless event.type == :done

        translation_workflow.signal(
          workflow_instance_id: workflow_instance_id,
          event: :translation_completed,
          payload: {
            answer: event.payload[:output],
            execution_id: event.payload[:execution_id].to_s,
            journal_position: event.payload[:journal_position]
          }
        )
      }
    )
    agent.invoke_async(ctx.query)

    nil
  }

  state :complete

  transition(
    from: :translating,
    on: :translation_completed,
    to: :complete,
    action: lambda { |ctx, event|
      ctx.merge(
        answer: event.payload[:answer],
        execution_id: event.payload[:execution_id],
        journal_position: event.payload[:journal_position]
      )
    }
  )
  transition from: :complete, to: :__finish__
end

workflow_result = OutputValidator.validate(
  "Agent event advances Workflow",
  check: ->(r) { r.answer.to_s.length >= 2 }
) do
  translation_workflow.invoke(
    {query: "This architecture keeps execution and state separate."},
    config: {workflow_instance_id: "example-26-workflow"}
  )
end

puts "Workflow answer:      #{workflow_result.answer}"
puts "Agent execution id:   #{workflow_result.execution_id}"
puts "Agent journal pos.:    #{workflow_result.journal_position}"
puts

puts "--- Pattern 3: timeout is distinct from explicit cancellation ---"

timeout_events = []
timeout_token = Phronomy::Concurrency::CancellationToken.timeout_after(-1)
timeout_agent = TranslationAgent.new(
  on_event: ->(event) { timeout_events << event.type }
)

timeout_task = timeout_agent.invoke_async(
  "This call should never reach the model.",
  config: {cancellation_token: timeout_token}
)

begin
  timeout_task.wait_result
rescue Phronomy::TimeoutError => e
  puts "Caught:  #{e.class}"
  puts "Events:  #{timeout_events.inspect}"
end
