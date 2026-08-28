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

    agent = DraftAgent.new(
      on_event: lambda { |event|
        next unless event.type == :done

        mail_workflow.signal(
          workflow_instance_id: workflow_instance_id,
          event: :draft_completed,
          payload: {draft: event.payload[:output].strip}
        )
      }
    )
    agent.invoke_async("Topic: #{state.topic}")

    nil
  }

  wait_state :awaiting_approval
  state :send, action: SEND_NODE

  transition(
    from: :draft,
    on: :draft_completed,
    to: :awaiting_approval,
    action: ->(ctx, event) { ctx.merge(draft: event.payload[:draft]) }
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

release_agent = ReleaseAgent.new
pending = release_agent.invoke("Publish version 2.4.0 to production.")

unless pending[:suspended]
  raise "Expected the approval-required tool call to suspend the Agent execution."
end

request = pending.fetch(:approval_request)
item = request.items.first
execution_id = pending.fetch(:execution_id)

puts "Execution suspended: #{pending[:suspended]}"
puts "Execution id:        #{execution_id}"
puts "Approval id:         #{request.id}"
puts "Tool:                #{item.tool_name}"
puts "Safe arguments:      #{item.arguments.inspect}"
puts "Approval facts:      #{item.facts.inspect}"
puts

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

# If the application still has `release_agent`, it may call
# `release_agent.approve(...)` directly. This lookup demonstrates the other
# common boundary: a later request still in the same Ruby process has only the
# execution_id and needs the existing live owner Agent.
owner = ReleaseAgent.live_for_execution(execution_id)
raise "live owner mismatch" unless owner.equal?(release_agent)

resumed = owner.approve(
  execution_id,
  approval_request_id: request.id,
  approved: approved
)

puts "Resolved live owner: #{owner.class} (same object=#{owner.equal?(release_agent)})"
puts "Tool approved:       #{approved}"
puts "Execution rejected:  #{!!resumed[:rejected]}"
puts "Agent output:        #{resumed[:output]}"
