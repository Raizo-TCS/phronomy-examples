#!/usr/bin/env ruby
# frozen_string_literal: true

# 26 Agent async events + Workflow coordination
#
# Shows two complementary public Agent async surfaces:
#
#   Agent lifecycle observation:
#     Agent#invoke_async -> structured on_event lifecycle events
#
#   Terminal completion coordination:
#     Workflow#task_state -> Agent#invoke_async -> apply -> FSM transition
#
# Also demonstrates framework-owned state-entry correlation and timeout classification.

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

puts "--- Pattern 1: invoke_async lifecycle event + TaskResult result ---"

Phronomy::Agent.open_scope do |agents|
  events = []
  agent = agents.create(TranslationAgent,
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

  puts "--- Pattern 2: Agent TaskResult completion advances a task_state ---"
end

class TranslationState
  include Phronomy::WorkflowContext

  field :query, type: :replace, default: ""
  field :answer, type: :replace, default: ""
  field :execution_id, type: :replace, default: ""
  field :journal_position, type: :replace, default: 0
end

Phronomy::Agent.open_scope do |agents|
  translation_workflow = Phronomy::Workflow.define(TranslationState) do
    initial :translating

    task_state :translating,
      start: ->(state) { agents.create_async(TranslationAgent).flat_map { |agent| agent.invoke_async(state.query) } },
      apply: ->(state, result) {
        state.merge(
          answer: result.fetch(:output),
          execution_id: result.fetch(:execution_id).to_s,
          journal_position: result.fetch(:journal_position)
        )
      }

    state :complete
    transition from: :translating, to: :complete
    transition from: :complete, to: :__finish__
  end

  workflow_result = OutputValidator.validate(
    "Agent TaskResult completion advances Workflow",
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
end

Phronomy::Agent.open_scope do |agents|
  timeout_events = []
  timeout_token = Phronomy::Concurrency::CancellationToken.timeout_after(-1)
  timeout_agent = agents.create(TranslationAgent,
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
end
