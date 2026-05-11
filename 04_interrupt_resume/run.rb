#!/usr/bin/env ruby
# frozen_string_literal: true

# 04 Interrupt / Resume
#
# Demonstrates the human-in-the-loop pattern: the graph generates an email
# draft, then interrupts before the :send node so a human can approve.
# On approval the graph is resumed and completes; on rejection nothing is
# sent.

require_relative "../shared/llm_config"
require "phronomy"

class MailState
  include Phronomy::Graph::State

  field :topic,    type: :replace, default: ""
  field :draft,    type: :replace, default: ""
  field :approved, type: :replace, default: false
end

llm = lambda do |input|
  chat = RubyLLM.chat(model: LLMConfig::MODEL, provider: LLMConfig::PROVIDER, assume_model_exists: true)
  chat.with_instructions(input[:system]) if input[:system]
  chat.ask(input[:user]).content
end

draft_node = lambda do |state|
  draft = llm.call({
    system: "You are a business email expert. Write a polite email including subject and body.",
    user:   "Topic: #{state.topic}"
  })
  state.merge(draft: draft.strip)
end

send_node = lambda do |state|
  puts
  puts "[SENT] Email sent successfully."
  state.merge(approved: true)
end

graph = Phronomy::Graph::StateGraph.new(MailState)
graph.add_node(:draft, draft_node)
graph.add_node(:send,  send_node)
graph.set_entry_point(:draft)
graph.add_edge(:draft, :send)
graph.add_edge(:send,  Phronomy::Graph::StateGraph::FINISH)

compiled = graph.compile
compiled.interrupt_before(:send) { |_state| :halt }

puts "=== Interrupt / Resume Example ==="
topic = "Project completion report"
puts "Topic: #{topic}"

state = compiled.invoke({topic: topic})

puts
puts "[DRAFT GENERATED]"
puts state.draft
puts

print "Approve and send? [yes/no]: "
answer = (ARGV.shift&.strip&.downcase) || ($stdin.gets&.strip&.downcase)
if answer == "yes"
  compiled.resume(state: state)
else
  puts
  puts "[CANCELLED] Draft was not sent."
end
