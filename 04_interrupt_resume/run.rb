#!/usr/bin/env ruby
# frozen_string_literal: true

# 04 Interrupt / Resume
#
# Demonstrates the human-in-the-loop pattern: the workflow generates an email
# draft, then waits at :awaiting_approval so a human can approve.
# On approval the workflow is resumed and completes; on rejection nothing is
# sent.
#
# The entry action starts the async Agent call and returns immediately. When
# the Agent finishes it signals :draft_completed; the transition action copies
# the draft into the context before the workflow halts at :awaiting_approval.

require_relative "../shared/llm_config"
require_relative "../shared/output_validator"
require "phronomy"

class MailState
  include Phronomy::WorkflowContext

  field :topic,    type: :replace, default: ""
  field :draft,    type: :replace, default: ""
  field :approved, type: :replace, default: false
end

class DraftAgent < Phronomy::Agent::Base
  model        LLMConfig::MODEL
  provider     LLMConfig::PROVIDER
  instructions "You are a business email expert. Write a polite email including subject and body."
end

SEND_NODE = ->(state) {
  puts
  puts "[SENT] Email sent successfully."
  state.merge(approved: true)
}

workflow = nil
workflow = Phronomy::Workflow.define(MailState) do
  initial :draft

  # :draft — active state: entry starts the Agent call and returns immediately.
  state :draft
  entry :draft, ->(state) {
    thread_id = state.thread_id
    topic     = state.topic
    DraftAgent.new.invoke_async(
      "Topic: #{topic}",
      on_event: ->(event) {
        next unless event.type == :done
        workflow.signal(
          thread_id: thread_id,
          event: :draft_completed,
          payload: {draft: event.payload[:output].strip}
        )
      }
    )
    state
  }

  wait_state :awaiting_approval
  state :send, action: SEND_NODE

  transition(
    from: :draft,
    on: :draft_completed,
    to: :awaiting_approval,
    action: ->(ctx, event) { ctx.merge(draft: event.payload[:draft]) }
  )
  transition from: :send,  to: :__finish__
  transition from: :awaiting_approval, on: :approve, to: :send
end

puts "=== Interrupt / Resume Example ==="
topic = "Project completion report"
puts "Topic: #{topic}"

state = OutputValidator.validate(
  "email draft generated for topic",
  check: ->(r) { r.draft.length >= 100 }
) { workflow.invoke({topic: topic}) }

puts
puts "[DRAFT GENERATED]"
puts state.draft
puts

print "Approve and send? [yes/no]: "
answer = (ARGV.shift&.strip&.downcase) || ($stdin.gets&.strip&.downcase)
if answer == "yes"
  workflow.send_event(state: state, event: :approve)
else
  puts
  puts "[CANCELLED] Draft was not sent."
end
