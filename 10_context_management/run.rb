#!/usr/bin/env ruby
# frozen_string_literal: true

# 10 Context Management
#
# Demonstrates phronomy's context window management features without making
# any real LLM API calls.  Each section is self-contained and printable.

require_relative "../shared/llm_config"
require "phronomy"
require "ostruct"

puts "=== Context Management Example ===\n\n"

# -----------------------------------------------------------------------
# 1. TokenEstimator
# -----------------------------------------------------------------------
puts "--- 1. TokenEstimator ---"
sample = "Hello, world!"
tokens = Phronomy::LlmContextWindow::TokenEstimator.estimate(sample)
puts "\"#{sample}\" => #{tokens} tokens (estimated)"
puts

# -----------------------------------------------------------------------
# 2. TokenBudget (explicit values — no model registry lookup needed)
# -----------------------------------------------------------------------
puts "--- 2. TokenBudget (explicit values) ---"
budget = Phronomy::LlmContextWindow::TokenBudget.new(
  context_window:    8192,
  max_output_tokens: 1024,
  overhead:           200
)
puts "context_window:    #{budget.context_window}"
puts "max_output_tokens: #{budget.max_output_tokens}"
puts "overhead:           #{budget.overhead}"
puts "effective_input:   #{budget.effective_input_limit}"
puts

# -----------------------------------------------------------------------
# 3. config[:messages] — application-managed conversation history
#    Phronomy does not manage history internally. The app owns the array
#    and passes prior messages via config[:messages]. Each invoke returns
#    the updated history in result[:messages].
# -----------------------------------------------------------------------
puts "--- 3. config[:messages] — application-managed conversation history ---"

# Simulate two prior turns stored by the application.
history = [
  OpenStruct.new(role: :user,      content: "Hi, my name is Alice."),
  OpenStruct.new(role: :assistant, content: "Hello Alice! How can I help you?"),
  OpenStruct.new(role: :user,      content: "What is the weather today?"),
  OpenStruct.new(role: :assistant, content: "I don't have live weather data.")
]

puts "Application-managed history: #{history.length} messages"
puts "Newest message: [#{history.last.role}] #{history.last.content}"
puts "Pass to next invoke: config: { messages: history, thread_id: 'session-1' }"
puts "After invoke: history = result[:messages]  # save the updated array"
puts

# -----------------------------------------------------------------------
# 4. Limiting history size — keep last N messages
#    Applications control which messages to pass. Slice the history array
#    to stay within a budget before the next invoke.
# -----------------------------------------------------------------------
puts "--- 4. Limiting history size (keep last N messages) ---"

all_messages = (1..20).flat_map do |i|
  [
    OpenStruct.new(role: :user,      content: "Question #{i}: What about topic #{i}?"),
    OpenStruct.new(role: :assistant, content: "Answer #{i}: Here is information about #{i}.")
  ]
end

recent_messages = all_messages.last(10)
puts "Total history:             #{all_messages.length} messages"
puts "Passed to agent (last 10): #{recent_messages.length} messages"
puts "Oldest kept: [#{recent_messages.first.role}] #{recent_messages.first.content}"
puts "Newest kept: [#{recent_messages.last.role}]  #{recent_messages.last.content}"
puts

# -----------------------------------------------------------------------
# 5. VectorStore::InMemory — cosine similarity search
# -----------------------------------------------------------------------
puts "--- 5. VectorStore::InMemory ---"

store = Phronomy::Agent::Context::Knowledge::VectorStore::InMemory.new
store.add(id: "A", embedding: [1.0, 0.0], metadata: { label: "A" })
store.add(id: "B", embedding: [0.0, 1.0], metadata: { label: "B" })
store.add(id: "C", embedding: [0.7, 0.7], metadata: { label: "C" })

query_vec = [1.0, 0.0]
results   = store.search(query_embedding: query_vec, k: 3)

puts "Added #{store.size} documents."
puts "Top result for query #{query_vec}: \"#{results.first[:metadata][:label]}\"" \
     " with score #{results.first[:score].round(4)}"
results.each do |r|
  puts "  #{r[:id]}: score=#{r[:score].round(4)}"
end
puts

# -----------------------------------------------------------------------
# 6. Context::Assembler — fitting history within a token budget
#    Assembler assembles system prompt + messages within effective_input_limit.
#    Older messages are automatically dropped to keep the context lean.
# -----------------------------------------------------------------------
puts "--- 6. Context::Assembler — fit history within a token budget ---"

tight_budget = Phronomy::LlmContextWindow::TokenBudget.new(
  context_window:    512,
  max_output_tokens: 128,
  overhead:          50
)
long_history = (1..10).flat_map do |i|
  [
    OpenStruct.new(role: :user,      content: "Turn #{i}: question about topic #{i}?"),
    OpenStruct.new(role: :assistant, content: "Turn #{i}: answer covering topic #{i}.")
  ]
end

builder = Phronomy::LlmContextWindow::Assembler.new(budget: tight_budget)
  .add_instruction("You are a helpful assistant.")
  .add_messages(long_history)

ctx = builder.build
puts "History provided:       #{long_history.length} messages"
puts "After budget trimming:  #{ctx[:messages].length} messages (newest kept)"
estimated = Phronomy::LlmContextWindow::TokenEstimator.estimate(ctx[:messages])
puts "Estimated tokens used:  ~#{estimated} / #{tight_budget.effective_input_limit} available"
puts

# -----------------------------------------------------------------------
# 7. Custom Tokenizer — swap the built-in heuristic with a lambda
# -----------------------------------------------------------------------
puts "--- 7. Custom Tokenizer ---"

sample_text = "Hello, world!"
default_estimate = Phronomy::LlmContextWindow::TokenEstimator.estimate(sample_text)

# Replace with a "word count" tokenizer as a simple demonstration.
Phronomy::LlmContextWindow::TokenEstimator.tokenizer = ->(text) { text.split.length }

custom_estimate = Phronomy::LlmContextWindow::TokenEstimator.estimate(sample_text)
puts "Text: \"#{sample_text}\""
puts "  default heuristic (len/4): #{default_estimate} tokens"
puts "  custom tokenizer (words):  #{custom_estimate} tokens"

# Restore default before subsequent sections rely on it.
Phronomy::LlmContextWindow::TokenEstimator.tokenizer = nil
puts "  restored default:          #{Phronomy::LlmContextWindow::TokenEstimator.estimate(sample_text)} tokens"
puts

# -----------------------------------------------------------------------
# 8. Context::Assembler + LLM — assemble context within a budget, then call
#    the LLM.  Evidence: print message counts and estimated vs actual tokens.
# -----------------------------------------------------------------------
puts "--- 8. Context::Assembler + LLM ---"

# Build a modest budget to demonstrate truncation.
ctx_budget = Phronomy::LlmContextWindow::TokenBudget.new(
  context_window:    1024,
  max_output_tokens: 256,
  overhead:          100
)
puts "Budget: context_window=#{ctx_budget.context_window}, " \
     "max_output_tokens=#{ctx_budget.max_output_tokens}, " \
     "overhead=#{ctx_budget.overhead}"
puts "  → effective_input_limit: #{ctx_budget.effective_input_limit} tokens"

# Simulate a long history (20 turns) that far exceeds the budget.
history = (1..20).flat_map do |i|
  [
    OpenStruct.new(role: :user,      content: "Turn #{i}: What is feature number #{i}?"),
    OpenStruct.new(role: :assistant, content: "Feature #{i} does the following: " + ("blah " * 10).strip)
  ]
end

builder = Phronomy::LlmContextWindow::Assembler.new(budget: ctx_budget)
  .add_instruction("You are a helpful assistant. Answer in one sentence.")
  .add_knowledge("phronomy is a Ruby AI agent framework.", type: :entity)
  .add_messages(history)

ctx = builder.build
est_history = Phronomy::LlmContextWindow::TokenEstimator.estimate(ctx[:messages])

puts "History stored:       #{history.length} messages"
puts "Messages within budget: #{ctx[:messages].length} messages (newest kept)"
puts "Estimated tokens used:  #{est_history} / #{ctx_budget.effective_input_limit} available"

# Call the LLM with only the budget-constrained context.
chat = RubyLLM.chat(
  model:                LLMConfig::MODEL,
  provider:             LLMConfig::PROVIDER,
  assume_model_exists:  true
)
ctx[:messages].each { |m| chat.messages << m }
response = chat.ask("Summarise what you know about phronomy in one sentence.")

puts "LLM response:   #{response.content}"
if response.tokens
  puts "Actual usage:   input=#{response.tokens.input}, " \
       "output=#{response.tokens.output} tokens"
end
puts

# -----------------------------------------------------------------------
# 9. Agent + config[:messages] — multi-turn conversation with history
#    result[:messages] contains the full updated history after each call.
#    Pass it back as config[:messages] to maintain context across turns.
# -----------------------------------------------------------------------
puts "--- 9. Agent + config[:messages] multi-turn conversation ---"

# Define a simple agent that answers in one sentence.
class ContextDemoAgent < Phronomy::Agent::Base
  model       LLMConfig::MODEL
  provider    LLMConfig::PROVIDER
  instructions "You are a concise assistant. Answer in one sentence only."
  max_output_tokens 256
  context_overhead  80
end

session_messages = []

r1 = ContextDemoAgent.new.invoke(
  "My name is Alice. Please remember it.",
  messages: session_messages, thread_id: "demo"
)
session_messages = r1[:messages]
puts "Turn 1 response: #{r1[:output][0, 70]}"
puts "History after turn 1: #{session_messages.length} messages"

r2 = ContextDemoAgent.new.invoke(
  "What is my name?",
  messages: session_messages, thread_id: "demo"
)
session_messages = r2[:messages]
puts "Turn 2 response: #{r2[:output][0, 70]}"
puts "History after turn 2: #{session_messages.length} messages"
puts "(Agent recalled 'Alice' from the messages passed via messages:)"
puts

# -----------------------------------------------------------------------
# 10. static_knowledge DSL + ContextVersionCache
#     The static text is SHA-256 fingerprinted once per agent instance;
#     subsequent calls skip rebuilding the system text (cache hit).
# -----------------------------------------------------------------------
puts "--- 10. static_knowledge DSL + ContextVersionCache ---"

class StaticKnowledgeAgent < Phronomy::Agent::Base
  model       LLMConfig::MODEL
  provider    LLMConfig::PROVIDER
  instructions "You are a helpful assistant."
  max_output_tokens 64
  static_knowledge Phronomy::Agent::Context::Knowledge::Source::StaticKnowledge.new(
    "Policy: always reply in exactly one sentence.",
    type: :policy
  )
end

sk_agent = StaticKnowledgeAgent.new
r_sk1 = sk_agent.invoke("Say 'first call ok'.")
fp1 = sk_agent.instance_variable_get(:@_context_version_cache)&.fingerprint

r_sk2 = sk_agent.invoke("Say 'second call ok'.")
fp2 = sk_agent.instance_variable_get(:@_context_version_cache)&.fingerprint

puts "First call:  #{r_sk1[:output][0, 70]}"
puts "Second call: #{r_sk2[:output][0, 70]}"
puts "Fingerprint unchanged: #{fp1 == fp2}  (system text re-used on 2nd call)"
puts

# -----------------------------------------------------------------------
# 11. on_trim callback
#     The oldest message is removed before the LLM call so the model
#     always receives at most the most recent conversation context.
#     Pass prior history via config[:messages]; on_trim receives the full
#     message_elements list and may call ctx.remove(seq) to drop entries.
# -----------------------------------------------------------------------
puts "--- 11. on_trim callback ---"

class TrimDemoAgent < Phronomy::Agent::Base
  model       LLMConfig::MODEL
  provider    LLMConfig::PROVIDER
  instructions "You are a helpful assistant."
  max_output_tokens 64

  on_trim do |ctx|
    first = ctx.message_elements.first
    ctx.remove(first[:seq]) if first
  end
end

trim_session = []
r_trim1 = TrimDemoAgent.new.invoke("Say 'turn 1'.",
  config: { messages: trim_session })
trim_session = r_trim1[:messages]
r_trim2 = TrimDemoAgent.new.invoke("Say 'turn 2'.",
  config: { messages: trim_session })
puts "Turn 2 response: #{r_trim2[:output][0, 70]}"
puts "(on_trim drops the oldest message from the LLM view before each call)"
puts

# -----------------------------------------------------------------------
# 12. on_compaction_trigger + on_compact
#     The trigger always fires; on_compact replaces the oldest message
#     with a brief summary string, keeping the context window lean.
# -----------------------------------------------------------------------
puts "--- 12. on_compaction_trigger + on_compact ---"

class CompactionDemoAgent < Phronomy::Agent::Base
  model       LLMConfig::MODEL
  provider    LLMConfig::PROVIDER
  instructions "You are a helpful assistant."
  max_output_tokens 64

  on_compaction_trigger { |_ctx| true }

  on_compact do |ctx|
    next if ctx.message_elements.empty?
    ctx.compact(0..0) do |elements|
      excerpt = elements.first[:message].content[0, 60]
      "Summary of earlier turn: #{excerpt}"
    end
  end
end

cmpct_session = []
r_cmpct1 = CompactionDemoAgent.new.invoke("Say 'first message'.",
  config: { messages: cmpct_session })
cmpct_session = r_cmpct1[:messages]
r_cmpct2 = CompactionDemoAgent.new.invoke("Say 'after compaction'.",
  config: { messages: cmpct_session })
puts "Response after compaction: #{r_cmpct2[:output][0, 70]}"
puts "(on_compact replaced the oldest message with a summary before the LLM call)"
puts

puts "=== Done ==="
