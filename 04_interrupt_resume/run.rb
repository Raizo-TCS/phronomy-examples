#!/usr/bin/env ruby
# frozen_string_literal: true

# 04 Human-in-the-loop
#
# Demonstrates two distinct Phronomy HITL mechanisms:
#
# 1. Workflow wait_state + send_event:
#    business-process approval controlled by the Workflow FSM.
#
# 2. Agent tool approval:
#    a capability declares requires_approval; Agent execution is suspended
#    before the side effect and resumed by the live Agent owner.

require "thread"
require_relative "../shared/llm_config"
require_relative "../shared/output_validator"
require "phronomy"

class MailState
  include Phronomy::WorkflowContext

  field :topic, type: :replace, default: ""
  field :draft, type: :replace, default: ""
  field :approved, type: :replace, default: false
end

class DraftAgent < Phronomy::Agent::Base
  agent_definition id: "example-04-draft-agent", version: 2

  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  instructions "Write a polite business email including a subject and body."
end

def event_payload!(event)
  payload = event.payload || {}
  raise payload[:error] if payload[:error]
  payload
end

SEND_NODE = lambda do |state|
  puts
  puts "[WORKFLOW] Email sent."
  state.merge(approved: true)
end

mail_workflow = nil
mail_workflow = Phronomy::Workflow.define(MailState) do
  initial :draft

  state :draft
  entry :draft, lambda { |state|
    workflow_instance_id = state.workflow_instance_id

    agent = DraftAgent.new
    task = agent.invoke_async("Topic: #{state.topic}").map do |result|
      {draft: result.fetch(:output).strip}
    end

    task.on_complete do |payload, error|
      mail_workflow.signal(
        workflow_instance_id: workflow_instance_id,
        event: :draft_completed,
        payload: error ? {error: error} : payload
      )
    end

    nil
  }

  wait_state :awaiting_approval
  state :send, action: SEND_NODE

  transition(
    from: :draft,
    on: :draft_completed,
    to: :awaiting_approval,
    action: ->(ctx, event) {
      ctx.merge(draft: event_payload!(event).fetch(:draft))
    }
  )
  transition from: :awaiting_approval, on: :approve, to: :send
  transition from: :send, to: :__finish__
end

puts "=== 04 Human-in-the-loop ==="
puts
puts "--- Part 1: Workflow wait_state / send_event ---"

topic = "Project completion report"
state = OutputValidator.validate(
  "email draft generated",
  check: ->(r) { r.draft.length >= 100 }
) { mail_workflow.invoke({topic: topic}) }

puts state.draft
puts

workflow_answer = ARGV.shift
unless workflow_answer
  print "Approve the Workflow draft? [yes/no]: "
  workflow_answer = $stdin.gets&.strip&.downcase
end

if workflow_answer == "yes"
  state = mail_workflow.send_event(state: state, event: :approve)
  puts "Workflow approved=#{state.approved}"
else
  puts "[WORKFLOW] Draft was not sent."
end

puts
puts "--- Part 2: Agent tool approval / live owner lookup ---"

class PublishReleaseTool < Phronomy::Tool::Base
  description "Publish a software release to an environment."
  param :version, type: :string, desc: "Release version"
  param :environment, type: :string, desc: "Target environment"

  requires_approval true

  approval_facts do |arguments, _context|
    {
      "operation" => "publish_release",
      "version" => arguments[:version] || arguments["version"],
      "environment" => arguments[:environment] || arguments["environment"]
    }
  end

  def execute(version:, environment:)
    "Published #{version} to #{environment}."
  end
end

class ReleaseAgent < Phronomy::Agent::Base
  agent_definition id: "example-04-release-agent", version: 1

  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  instructions <<~PROMPT
    You operate the release system.
    When the user asks to publish a release, you MUST call publish_release.
    Do not claim that a release was published without using the tool.
  PROMPT

  tools(PublishReleaseTool => "publish_release")
end

# Agent suspension is not terminal completion. The Task returned by invoke_async
# remains pending while approval is required. Wait for either the nonterminal
# approval event or an unexpected terminal completion so a model that does not
# request the tool cannot leave the application blocked on an approval-only queue.
approval_outcomes = Queue.new
release_agent = ReleaseAgent.new(
  on_event: ->(event) {
    next unless event.type == :approval_required

    approval_outcomes << [:approval_required, event.payload.fetch(:request)]
  }
)
original_task = release_agent.invoke_async("Publish version 2.4.0 to production.")
original_task.on_complete do |result, error|
  approval_outcomes << [:terminal, result, error]
end

outcome_type, outcome_value, outcome_error = approval_outcomes.pop
if outcome_type == :terminal
  raise outcome_error if outcome_error

  raise(
    "Expected the approval-required tool call to suspend the Agent execution, " \
    "but the Agent completed without requesting approval. " \
    "Output: #{outcome_value&.fetch(:output, nil).inspect}"
  )
end

request = outcome_value
item = request.items.first
execution_id = request.execution_id

puts "Execution suspended: true"
puts "Execution id:        #{execution_id}"
puts "Approval id:         #{request.id}"
puts "Tool:                #{item.tool_name}"
puts "Safe arguments:      #{item.arguments.inspect}"
puts "Approval facts:      #{item.facts.inspect}"
puts "Original Task done:  #{original_task.done?}"
puts

raise "Original Agent Task settled before approval" if original_task.done?

# This is intentionally a second, independent decision. Workflow approval above
# must never implicitly authorize a tool side effect.
#
# In a real HTTP/API application, authorize the caller BEFORE treating this
# execution as approvable. execution_id is routing identity, not an auth token.
agent_answer = ARGV.shift
unless agent_answer
  print "Approve the Agent tool execution? [yes/no]: "
  agent_answer = $stdin.gets&.strip&.downcase
end

approved = agent_answer == "yes"

# A later request in the same Ruby process may have only execution_id. Resolve
# the existing live owner; do not construct or reload a second Agent instance.
owner = ReleaseAgent.live_for_execution(execution_id)
raise "live owner mismatch" unless owner.equal?(release_agent)

# This call runs on the CLI/main thread, so the synchronous wrapper is allowed.
# It resumes the same suspended execution and waits for its terminal result.
resumed = owner.approve(
  execution_id,
  approval_request_id: request.id,
  approved: approved
)

# The original invoke_async Task observes the same logical execution and must
# settle to the same terminal result after approval/rejection resolution.
original_result = original_task.wait_result
raise "approval/original execution mismatch" unless
  original_result[:execution_id] == resumed[:execution_id]

puts "Resolved live owner: #{owner.class} (same object=#{owner.equal?(release_agent)})"
puts "Tool approved:       #{approved}"
puts "Execution rejected:  #{!!resumed[:rejected]}"
puts "Original Task done:  #{original_task.done?}"
puts "Agent output:        #{resumed[:output]}"
