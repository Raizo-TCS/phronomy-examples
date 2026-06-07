#!/usr/bin/env ruby
# frozen_string_literal: true

# 04 Interrupt / Resume
#
# Demonstrates the human-in-the-loop pattern: the workflow generates an email
# draft, then waits at :awaiting_approval so a human can approve.
# On approval the workflow is resumed and completes; on rejection nothing is
# sent.

require_relative "../shared/llm_config"
require_relative "../shared/output_validator"
require "phronomy"

class MailState
  include Phronomy::WorkflowContext

  field :topic,    type: :replace, default: ""
  field :draft,    type: :replace, default: ""
  field :approved, type: :replace, default: false
end

llm = lambda do |input|
  chat = RubyLLM.chat(model: LLMConfig::MODEL, **(LLMConfig::PROVIDER ? { provider: LLMConfig::PROVIDER, assume_model_exists: true } : {}))
  chat.with_instructions(input[:system]) if input[:system]
  chat.ask(input[:user]).content
end

DRAFT_NODE = ->(state) {
  draft = llm.call({
    system: "You are a business email expert. Write a polite email including subject and body.",
    user:   "Topic: #{state.topic}"
  })
  state.merge(draft: draft.strip)
}

SEND_NODE = ->(state) {
  puts
  puts "[SENT] Email sent successfully."
  state.merge(approved: true)
}

app = Phronomy::Workflow.define(MailState) do
  initial :draft
  state :draft, action: DRAFT_NODE
  wait_state :awaiting_approval
  state :send, action: SEND_NODE

  transition from: :draft, to: :awaiting_approval
  transition from: :send,  to: :__finish__

  transition from: :awaiting_approval, on: :approve, to: :send
end

puts "=== Interrupt / Resume Example ==="
topic = "Project completion report"
puts "Topic: #{topic}"

state = OutputValidator.validate(
  "email draft generated for topic",
  check: ->(r) { r.draft.length >= 100 }
) { app.invoke({topic: topic}) }

puts
puts "[DRAFT GENERATED]"
puts state.draft
puts

print "Approve and send? [yes/no]: "
answer = (ARGV.shift&.strip&.downcase) || ($stdin.gets&.strip&.downcase)
if answer == "yes"
  app.send_event(state: state, event: :approve)
else
  puts
  puts "[CANCELLED] Draft was not sent."
end
