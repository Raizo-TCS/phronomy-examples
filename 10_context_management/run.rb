#!/usr/bin/env ruby
# frozen_string_literal: true

# 10 Context Management
#
# Demonstrates phronomy's stateful Agent context management:
#
#   1. Agent.create — create a new stateful agent
#   2. Multi-turn conversation — same agent instance retains history
#   3. Agent.load  — reload a persisted agent by agent_id
#   4. transcript  — read conversation history from the Journal
#   5. result[:messages] is a projection, not storage
#   6. context: — import existing history on create
#   7. clear_transcript! — clear the LLM transcript generation
#   8. reset_context!    — clear transcript + memory in one call
#   9. max_output_tokens / context_window DSL
#  10. TokenBudget and TokenEstimator (utility, no LLM required)
#
# Sections 1–6 and 9–10 use the real LLM.
# Sections 7–8 require no LLM.

require_relative "../shared/llm_config"
require_relative "../shared/output_validator"
require "phronomy"

LLMConfig.apply_phronomy_defaults!

puts "=== 10 Context Management Example ===\n\n"

# ---------------------------------------------------------------------------
# 1. Agent.create — create a new stateful agent with InMemory persistence
# ---------------------------------------------------------------------------
puts "--- 1. Agent.create ---"

class ContextDemoAgent < Phronomy::Agent::Base
  agent_definition id: "example-10-context-demo-agent", version: 1

  model        LLMConfig::MODEL
  provider     LLMConfig::PROVIDER
  max_output_tokens LLMConfig::CONTEXT_WINDOW / 4

  instructions "You are a concise assistant. Answer in 1–2 sentences."
end

persistence = Phronomy::Persistence::InMemory.new

agent = ContextDemoAgent.create(
  agent_id: "demo-alice",
  persistence: persistence
)

puts "Created agent: #{agent.agent_id}"
puts

# ---------------------------------------------------------------------------
# 2. Multi-turn conversation — history lives in the Agent's Journal
# ---------------------------------------------------------------------------
puts "--- 2. Multi-turn conversation ---"

OutputValidator.validate(
  "turn 1: agent responds to name introduction",
  check: ->(r) { r[:output].length >= 5 }
) { agent.invoke("My name is Alice. Please remember it.") }

result2 = OutputValidator.validate(
  "turn 2: agent remembers the name",
  check: ->(r) { r[:output].downcase.include?("alice") }
) { agent.invoke("What is my name?") }

puts "Turn 2 response: #{result2[:output]}"
puts

# ---------------------------------------------------------------------------
# 3. Agent.load — reload the same agent by agent_id
# ---------------------------------------------------------------------------
puts "--- 3. Agent.load ---"

reloaded = ContextDemoAgent.load("demo-alice", persistence: persistence)
puts "Loaded agent: #{reloaded.agent_id}"

result3 = OutputValidator.validate(
  "reloaded agent still knows the name",
  check: ->(r) { r[:output].downcase.include?("alice") }
) { reloaded.invoke("Do you still remember my name?") }

puts "Reloaded response: #{result3[:output]}"
puts

# ---------------------------------------------------------------------------
# 4. transcript — read conversation history from the Journal
# ---------------------------------------------------------------------------
puts "--- 4. transcript ---"

records = reloaded.transcript
puts "Journal records in transcript: #{records.size}"
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

# ---------------------------------------------------------------------------
# 5. result[:messages] is a projection from the Journal, not the authority
# ---------------------------------------------------------------------------
puts "--- 5. result[:messages] is a read-only projection ---"

result5 = agent.invoke("Say the word 'projection' once.")
puts "Projection size: #{result5[:messages].size} messages"
puts "First message role: #{result5[:messages].first&.role}"
puts "(Messages are materialised from the Journal on each call.)"
puts

# ---------------------------------------------------------------------------
# 6. context: — import existing conversation history on create
# ---------------------------------------------------------------------------
puts "--- 6. context: import on create ---"

existing_history = [
  {role: :user,      content: "My name is Bob."},
  {role: :assistant, content: "Nice to meet you, Bob!"}
]

agent_bob = ContextDemoAgent.create(
  context: existing_history,
  persistence: persistence
)

result6 = OutputValidator.validate(
  "agent with imported context knows Bob",
  check: ->(r) { r[:output].downcase.include?("bob") }
) { agent_bob.invoke("Do you know my name?") }

puts "Response with imported context: #{result6[:output]}"
puts

# ---------------------------------------------------------------------------
# 7. clear_transcript! — advance the transcript generation
#    The canonical Journal is preserved; only the active LLM window resets.
# ---------------------------------------------------------------------------
puts "--- 7. clear_transcript! ---"

before_count = agent.transcript.size
agent.clear_transcript!
after_count  = agent.transcript.size

puts "Before clear_transcript!: #{before_count} records in transcript"
puts "After  clear_transcript!: #{after_count} records in transcript"
puts "(Journal entries are retained; only the active generation advances.)"
puts

# ---------------------------------------------------------------------------
# 8. reset_context! — clears both transcript generation and memory generation
# ---------------------------------------------------------------------------
puts "--- 8. reset_context! ---"

agent_bob.reset_context!
puts "reset_context! called on agent_bob."
puts "Transcript records after reset: #{agent_bob.transcript.size}"
puts

# ---------------------------------------------------------------------------
# 9. max_output_tokens / context_window DSL
# ---------------------------------------------------------------------------
puts "--- 9. max_output_tokens / context_window DSL ---"

class CompactAgent < Phronomy::Agent::Base
  agent_definition id: "example-10-compact-agent", version: 1

  model             LLMConfig::MODEL
  provider          LLMConfig::PROVIDER
  context_window    LLMConfig::CONTEXT_WINDOW
  max_output_tokens 128

  instructions "You are a very concise assistant. Reply in one short sentence."
end

compact = CompactAgent.new

result9 = OutputValidator.validate(
  "compact agent responds to greeting",
  check: ->(r) { r[:output].length >= 3 }
) { compact.invoke("Hello!") }

puts "CompactAgent response: #{result9[:output]}"
puts "context_window:    #{CompactAgent.context_window}"
puts "max_output_tokens: #{CompactAgent.max_output_tokens}"
puts

# ---------------------------------------------------------------------------
# 10. TokenBudget and TokenEstimator (no LLM required)
# ---------------------------------------------------------------------------
puts "--- 10. TokenBudget and TokenEstimator ---"

sample = "The quick brown fox jumps over the lazy dog."
tokens = Phronomy::LlmContextWindow::TokenEstimator.estimate(sample)
puts "Sample: \"#{sample}\""
puts "Estimated tokens: #{tokens}"

budget = Phronomy::LlmContextWindow::TokenBudget.new(
  context_window:    LLMConfig::CONTEXT_WINDOW,
  max_output_tokens: LLMConfig::CONTEXT_WINDOW / 4
)
puts "context_window:      #{budget.context_window}"
puts "max_output_tokens:   #{budget.max_output_tokens}"
puts "effective_input_limit: #{budget.effective_input_limit}"
puts "available (0 used):  #{budget.available(used: 0)}"
puts

puts "Done."
