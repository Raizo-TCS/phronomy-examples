#!/usr/bin/env ruby
# frozen_string_literal: true

# 29 Unified Persistence
#
# Demonstrates one Persistence backend serving both Agent durable state and
# Workflow workflow_states while live logical ownership remains with the active
# Agent / Workflow execution.

require_relative "../shared/llm_config"
require "phronomy"

persistence = Phronomy::Persistence::InMemory.new

Phronomy.configure do |config|
  config.persistence = persistence
end

class UnifiedPersistenceAgent < Phronomy::Agent::Base
  agent_definition id: "example-29-unified-persistence-agent", version: 1

  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  instructions <<~PROMPT
    You are demonstrating Phronomy persistence.
    Answer the user's question in one short sentence.
  PROMPT
end

puts "=== 29 Unified Persistence ==="
puts
puts "--- Agent durable state ---"

agent = UnifiedPersistenceAgent.create(
  agent_id: "example-29-agent",
  knowledge: ["The persistence demo keyword is Aurora."],
  metadata: {"example" => "29_unified_persistence"}
)

agent_result = agent.invoke(
  "What is the persistence demo keyword? Answer with the keyword."
)

puts "Agent id:      #{agent.agent_id}"
puts "Execution id:  #{agent_result[:execution_id]}"
puts "Agent output:  #{agent_result[:output]}"
puts "Transcript:    #{agent.transcript.size} records"

# This represents a later application boundary. The explicit backend makes the
# durable source unambiguous; do not continue mutating both Ruby objects as
# independent concurrent owners.
reloaded_agent = UnifiedPersistenceAgent.load(
  agent.agent_id,
  persistence: persistence
)

puts "Reloaded id:   #{reloaded_agent.agent_id}"
puts "Reloaded transcript: #{reloaded_agent.transcript.size} records"
puts

puts "--- Workflow durable state ---"

class ApprovalState
  include Phronomy::WorkflowContext

  field :request, type: :replace, default: ""
  field :status, type: :replace, default: "new"
end

approval_workflow = Phronomy::Workflow.define(ApprovalState) do
  initial :prepare

  state :prepare, action: ->(ctx) { ctx.merge(status: "prepared") }
  wait_state :awaiting_approval
  state :complete, action: ->(ctx) { ctx.merge(status: "approved") }

  transition from: :prepare, to: :awaiting_approval
  transition from: :awaiting_approval, on: :approve, to: :complete
  transition from: :complete, to: :__finish__
end

thread_id = "example-29-workflow"

halted = approval_workflow.invoke(
  {request: "Deploy release 29"},
  config: {thread_id: thread_id}
)

halted_record = persistence.workflow_states.load(thread_id)

puts "Workflow thread_id: #{halted.thread_id}"
puts "Workflow phase:     #{halted.phase}"
puts "Workflow status:    #{halted.status}"
puts "Durable revision:   #{halted_record.fetch(:revision)}"
puts "Durable phase:      #{halted_record.fetch(:snapshot).fetch(:phase)}"

completed = approval_workflow.send_event(
  state: halted,
  event: :approve
)

completed_record = persistence.workflow_states.load(thread_id)

puts
puts "After approval:"
puts "Workflow phase:     #{completed.phase}"
puts "Workflow status:    #{completed.status}"
puts "Durable revision:   #{completed_record.fetch(:revision)}"
puts "Durable phase:      #{completed_record.fetch(:snapshot).fetch(:phase)}"

puts
puts "--- Identity summary ---"
puts "agent_id     = #{agent.agent_id}"
puts "execution_id = #{agent_result[:execution_id]}"
puts "thread_id    = #{thread_id}"
puts
puts "These identifiers have different responsibilities."
puts "Workflow admission is process-local; optimistic revisions are not a distributed lock."
