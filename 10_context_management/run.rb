#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "../shared/llm_config"
require_relative "../shared/output_validator"
require "phronomy"

LLMConfig.apply_phronomy_defaults!

puts "=== 10 Context Management Example ===\n\n"

class ContextDemoAgent < Phronomy::Agent::Base
  agent_definition id: "example-10-context-demo-agent", version: 1

  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  context_window LLMConfig::CONTEXT_WINDOW
  max_output_tokens LLMConfig::CONTEXT_WINDOW / 4
  instructions "You are a concise assistant. Always recall and reference earlier conversation context accurately. Answer in 1-2 sentences."
end

persistence = Phronomy::Persistence::InMemory.new

puts "--- 1. Agent.create ---"
agent = ContextDemoAgent.create(agent_id: "demo-alice", persistence: persistence)
puts "Created agent: #{agent.agent_id}\n\n"

puts "--- 2. Multi-turn conversation ---"
OutputValidator.validate(
  "turn 1: agent responds to name introduction",
  check: ->(r) { r[:output].length >= 5 }
) { agent.invoke("My name is Alice. Please remember it.") }
result2 = OutputValidator.validate(
  "turn 2: agent remembers the name",
  check: ->(r) { r[:output].downcase.include?("alice") }
) { agent.invoke("What name did I tell you at the start of our conversation?") }
puts "Turn 2 response: #{result2[:output]}\n\n"

puts "--- 3. Agent.load ---"
reloaded = ContextDemoAgent.load("demo-alice", persistence: persistence)
puts "Loaded agent: #{reloaded.agent_id}"
result3 = OutputValidator.validate(
  "reloaded agent still knows the name",
  check: ->(r) { r[:output].downcase.include?("alice") }
) { reloaded.invoke("Do you still remember my name?") }
puts "Reloaded response: #{result3[:output]}\n\n"

puts "--- 4. transcript ---"
records = reloaded.transcript
puts "Transcript records: #{records.size}"
records.each do |record|
  raw = persistence.contents.fetch_text(record.content_ref)
  text = begin
    JSON.parse(raw)["content"] || raw
  rescue JSON::ParserError
    raw
  end
  puts "  [#{record.role}] #{text.slice(0, 80).gsub("\n", " ")}"
end
puts

puts "--- 5. result[:messages] projection ---"
result5 = agent.invoke("Say the word 'projection' once.")
puts "Projection size: #{result5[:messages].size}"
puts "First role: #{result5[:messages].first&.role}"
puts "The Agent Journal remains the persistent authority.\n\n"

puts "--- 6. context: import ---"
existing_history = [
  {role: :user, content: "My name is Bob."},
  {role: :assistant, content: "Nice to meet you, Bob!"}
]
agent_bob = ContextDemoAgent.create(context: existing_history, persistence: persistence)
result6 = OutputValidator.validate(
  "agent with imported context knows Bob",
  check: ->(r) { r[:output].downcase.include?("bob") }
) { agent_bob.invoke("Do you know my name?") }
puts "Imported-context response: #{result6[:output]}\n\n"

puts "--- 7. Persistent Knowledge ---"
agent_carol = ContextDemoAgent.create(
  knowledge: ["Customer profile: name=Carol, plan=Enterprise, region=Japan."],
  persistence: persistence
)
agent_carol.add_knowledge(
  "Customer preference: reply language is Japanese.",
  metadata: {"source" => "customer-profile", "category" => "preference"}
)
result7 = OutputValidator.validate(
  "knowledge is available to the agent",
  check: ->(r) {
    output = r[:output].downcase
    output.include?("enterprise") || output.include?("japan")
  }
) { agent_carol.invoke("What plan and region are recorded for this customer?") }
puts "Knowledge response: #{result7[:output]}"
puts "Transcript records: #{agent_carol.transcript.size}"
puts "Knowledge itself is not part of the public transcript.\n\n"

puts "--- 8. Reset APIs ---"
before_count = agent.transcript.size
agent.clear_transcript!
puts "clear_transcript!: #{before_count} -> #{agent.transcript.size} transcript records"
agent_carol.clear_knowledge!
puts "clear_knowledge! called on Carol's agent."
agent_bob.reset_context!
puts "reset_context! called on Bob's agent."
puts "Bob transcript records after reset: #{agent_bob.transcript.size}\n\n"

puts "--- 9. context_window / max_output_tokens ---"
class CompactAgent < Phronomy::Agent::Base
  agent_definition id: "example-10-compact-agent", version: 1

  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  context_window LLMConfig::CONTEXT_WINDOW
  max_output_tokens 128
  instructions "You are a very concise assistant. Reply in one short sentence."
end
compact = CompactAgent.new
result9 = OutputValidator.validate(
  "compact agent responds",
  check: ->(r) { r[:output].length >= 3 }
) { compact.invoke("Hello!") }
puts "CompactAgent response: #{result9[:output]}"
puts "context_window: #{CompactAgent.context_window}"
puts "max_output_tokens: #{CompactAgent.max_output_tokens}"
puts "\nDone."
