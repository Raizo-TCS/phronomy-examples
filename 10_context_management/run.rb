#!/usr/bin/env ruby
# frozen_string_literal: true

# 10 Stateful Agent Context
#
# The important architecture demonstrated here is:
#
#   persistent Agent Journal
#       -> Context candidates
#       -> Context Policy / token budget
#       -> per-call LLMInputManifest
#       -> provider-specific messages
#
# The Journal remains the canonical history. A particular LLM call may receive
# only a selected projection of that history.

require_relative "../shared/llm_config"
require_relative "../shared/output_validator"
require "phronomy"

class ContextDemoAgent < Phronomy::Agent::Base
  agent_definition id: "example-10-context-demo-agent", version: 2

  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER

  # Deliberately small enough that the imported history cannot all fit into one
  # model call. This makes the Journal-vs-projection distinction visible.
  context_window 4096
  max_output_tokens 512

  instructions <<~PROMPT
    You are a project assistant.
    Answer from the conversation history and persistent knowledge available to you.
    Be concise. If asked for a remembered project name, answer it directly.
  PROMPT
end

def imported_history
  messages = []

  # Put deliberately verbose historical turns first so the per-call context
  # policy has something meaningful to omit. Keep the fact validated by this
  # example near the recent edge; the example should demonstrate projection,
  # not depend on a particular pruning heuristic retaining an ancient fact.
  14.times do |i|
    filler = ("archived planning note #{i + 1}; " * 45).strip
    messages << {
      role: "user",
      content: "Historical planning turn #{i + 1}: #{filler}"
    }
    messages << {
      role: "assistant",
      content: "Recorded historical planning turn #{i + 1}. #{filler}"
    }
  end

  messages.concat([
    {
      role: "user",
      content: "The project codename is Atlas. Remember that exact name."
    },
    {
      role: "assistant",
      content: "Understood. The project codename is Atlas."
    }
  ])

  messages
end

puts "=== 10 Stateful Agent Context ==="
puts

persistence = Phronomy::Persistence::InMemory.new

agent = ContextDemoAgent.create(
  agent_id: "example-10-atlas",
  persistence: persistence,
  context: imported_history,
  knowledge: [
    "Operational contact: support@example.test",
    "Atlas production change window: Sunday 02:00-04:00 UTC"
  ],
  metadata: {"example" => "10_context_management"}
)

puts "--- Canonical state vs one LLM call ---"
puts "Agent id:                    #{agent.agent_id}"
puts "Transcript records before:   #{agent.transcript.size}"

result = OutputValidator.validate(
  "agent remembers Atlas from persistent context",
  check: ->(r) { r[:output].to_s.downcase.include?("atlas") }
) { agent.invoke("What is the project codename? Answer with the name.") }

puts "Answer:                      #{result[:output]}"
puts "Transcript records after:    #{agent.transcript.size}"
puts "Messages sent in this call:   #{result[:messages].size}"
puts "Execution id:                 #{result[:execution_id]}"
puts "Journal position:              #{result[:journal_position]}"
puts
puts "The transcript count is canonical Agent history."
puts "The messages count is the projection selected for this specific model call."
puts "Context omission for a call does not delete Journal history."
puts

puts "--- Persistent Knowledge is separate from transcript ---"
transcript_before_knowledge = agent.transcript.size
agent.add_knowledge(
  "Escalation rule: production incidents must page the on-call engineer.",
  metadata: {"source" => "example-runtime-update"}
)
transcript_after_knowledge = agent.transcript.size

puts "Transcript before add_knowledge: #{transcript_before_knowledge}"
puts "Transcript after add_knowledge:  #{transcript_after_knowledge}"
puts "(Knowledge is a Context candidate, but not a transcript message.)"

knowledge_result = OutputValidator.validate(
  "agent uses Journal-backed knowledge",
  check: ->(r) { r[:output].to_s.include?("support@example.test") }
) { agent.invoke("What support email is stored in your persistent knowledge?") }

puts "Knowledge answer:             #{knowledge_result[:output]}"
puts "Journal position:              #{knowledge_result[:journal_position]}"
puts

puts "--- Reload the same logical Agent ---"
reloaded = ContextDemoAgent.load(agent.agent_id, persistence: persistence)

puts "Reloaded id:                  #{reloaded.agent_id}"
puts "Reloaded transcript records:  #{reloaded.transcript.size}"

reload_result = OutputValidator.validate(
  "reloaded agent retains persistent context",
  check: ->(r) { r[:output].to_s.downcase.include?("atlas") }
) { reloaded.invoke("What codename have we been using?") }

puts "Reloaded answer:              #{reload_result[:output]}"
puts

puts "--- Logical clears preserve append-only audit history internally ---"
reloaded.clear_transcript!
puts "Transcript after clear:       #{reloaded.transcript.size}"

reloaded.clear_knowledge!
puts "Knowledge cleared independently of transcript."

reloaded.reset_context!
puts "Context reset completed."
