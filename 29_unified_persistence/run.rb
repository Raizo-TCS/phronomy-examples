#!/usr/bin/env ruby
# frozen_string_literal: true

# 29 Unified Persistence
#
# Demonstrates one Persistence backend serving Agent durable state and Workflow
# workflow_states while process-local live ownership remains separate from the
# durable representation.

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
puts "--- Agent durable state and live ownership ---"

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

# Persistence can be inspected independently as the durable source of truth.
stored_root = persistence.agents.load(agent.agent_id)
puts "Durable Agent revision: #{stored_root.agent_revision}"
puts "Durable Journal head:   #{persistence.journals.head(agent.agent_id)}"

# In the same Runtime, .load resolves the existing live owner; it does not create
# a second mutable Agent object with the same agent_id.
resolved_owner = UnifiedPersistenceAgent.load(
  agent.agent_id,
  persistence: persistence
)
raise "same-process Agent ownership mismatch" unless resolved_owner.equal?(agent)
puts "Same-process load returns existing owner: #{resolved_owner.equal?(agent)}"
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

workflow_instance_id = "example-29-workflow"

halted = approval_workflow.invoke(
  {request: "Deploy release 29"},
  config: {workflow_instance_id: workflow_instance_id}
)

halted_record = persistence.workflow_states.load(workflow_instance_id)

puts "Workflow instance id: #{halted.workflow_instance_id}"
puts "Workflow phase:       #{halted.phase}"
puts "Workflow status:      #{halted.status}"
puts "Durable revision:     #{halted_record.fetch(:revision)}"
puts "Durable phase:        #{halted_record.fetch(:snapshot).fetch("phase")}"

completed = approval_workflow.send_event(
  state: halted,
  event: :approve
)

completed_record = persistence.workflow_states.load(workflow_instance_id)

puts
puts "After approval:"
puts "Workflow phase:       #{completed.phase}"
puts "Workflow status:      #{completed.status}"
puts "Durable revision:     #{completed_record.fetch(:revision)}"
puts "Durable phase:        #{completed_record.fetch(:snapshot).fetch("phase")}"

puts
puts "--- Identity summary ---"
puts "agent_id             = #{agent.agent_id}"
puts "execution_id         = #{agent_result[:execution_id]}"
puts "workflow_instance_id = #{workflow_instance_id}"
puts
puts "These identifiers have different responsibilities."
puts "Same-process live ownership and durable optimistic revisions are not distributed locks."
