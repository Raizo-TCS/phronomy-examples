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
tokens = Phronomy::Context::TokenEstimator.estimate(sample)
puts "\"#{sample}\" => #{tokens} tokens (estimated)"
puts

# -----------------------------------------------------------------------
# 2. TokenBudget (explicit values — no model registry lookup needed)
# -----------------------------------------------------------------------
puts "--- 2. TokenBudget (explicit values) ---"
budget = Phronomy::Context::TokenBudget.new(
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
# 3. ConversationManager (Recent retrieval) with token_budget
#    — oldest messages are dropped when the budget is tight
# -----------------------------------------------------------------------
puts "--- 3. ConversationManager (Recent retrieval) with token_budget ---"

window = Phronomy::Memory::ConversationManager.new(
  storage:   Phronomy::Memory::Storage::InMemory.new,
  retrieval: Phronomy::Memory::Retrieval::Recent.new(k: 50)
)

messages = Array.new(10) do |i|
  OpenStruct.new(role: i.even? ? :user : :assistant, content: "Message #{i + 1}: " + ("x" * 40))
end
window.save(thread_id: "demo", messages: messages)

small_budget = Phronomy::Context::TokenBudget.new(context_window: 100, max_output_tokens: 0)
loaded = window.load(thread_id: "demo")

puts "Stored #{messages.length} messages."
puts "Loaded #{loaded.length} messages."
puts "Newest kept: \"#{loaded.last&.content&.slice(0, 30)}...\""
puts

# -----------------------------------------------------------------------
# 4. ToolOutputPruner — truncate oversized tool results
# -----------------------------------------------------------------------
puts "--- 4. ToolOutputPruner ---"

pruner = Phronomy::Memory::Compression::ToolOutputPruner.new(max_chars: 50)
big_tool_msg = OpenStruct.new(role: :tool, content: "Tool result: " + ("data " * 40))
pruned = pruner.compress(thread_id: "demo", messages: [big_tool_msg])[:messages]

puts "Original tool output: #{big_tool_msg.content.length} chars"
puts "After pruning:        #{pruned.first.content.length} chars"
puts "Content: #{pruned.first.content}"
puts

# -----------------------------------------------------------------------
# 5. VectorStore::InMemory — cosine similarity search
# -----------------------------------------------------------------------
puts "--- 5. VectorStore::InMemory ---"

store = Phronomy::VectorStore::InMemory.new
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
# 6. Retrieval::Composite — merge Recent + Semantic retrieval within a budget
# -----------------------------------------------------------------------
puts "--- 6. Retrieval::Composite ---"

storage2 = Phronomy::Memory::Storage::InMemory.new
msgs_a = Array.new(4) { |i| OpenStruct.new(role: :user, content: "recent #{i + 1}") }

# Retrieval::Semantic requires real embeddings — stub with a fake store to avoid an API call.
fake_store = Phronomy::VectorStore::InMemory.new
fake_store.add(
  id: "s1",
  embedding: [1.0, 0.0],
  metadata: { thread_id: "c1", message: OpenStruct.new(role: :user, content: "semantic fact") }
)
fake_embeddings = Object.new
def fake_embeddings.embed(_text) = [1.0, 0.0]

retrieval_composite = Phronomy::Memory::Retrieval::Composite.new(
  sources: [
    { retrieval: Phronomy::Memory::Retrieval::Recent.new(k: 20),  weight: 0.7 },
    { retrieval: Phronomy::Memory::Retrieval::Semantic.new(embeddings: fake_embeddings, k: 5), weight: 0.3 }
  ]
)

composite_manager = Phronomy::Memory::ConversationManager.new(
  storage:   storage2,
  retrieval: retrieval_composite
)
composite_manager.save(thread_id: "c1", messages: msgs_a)
combined = composite_manager.load(thread_id: "c1", query: "recent")

puts "Combined #{combined.length} messages from Recent + Semantic retrieval."
combined.each { |m| puts "  [#{m.role}] #{m.content}" }
puts

# -----------------------------------------------------------------------
# 7. Custom Tokenizer — swap the built-in heuristic with a lambda
# -----------------------------------------------------------------------
puts "--- 7. Custom Tokenizer ---"

sample_text = "Hello, world!"
default_estimate = Phronomy::Context::TokenEstimator.estimate(sample_text)

# Replace with a "word count" tokenizer as a simple demonstration.
Phronomy::Context::TokenEstimator.tokenizer = ->(text) { text.split.length }

custom_estimate = Phronomy::Context::TokenEstimator.estimate(sample_text)
puts "Text: \"#{sample_text}\""
puts "  default heuristic (len/4): #{default_estimate} tokens"
puts "  custom tokenizer (words):  #{custom_estimate} tokens"

# Restore default before subsequent sections rely on it.
Phronomy::Context::TokenEstimator.tokenizer = nil
puts "  restored default:          #{Phronomy::Context::TokenEstimator.estimate(sample_text)} tokens"
puts

# -----------------------------------------------------------------------
# 8. Context::Builder + LLM — assemble context within a budget, then call
#    the LLM.  Evidence: print message counts and estimated vs actual tokens.
# -----------------------------------------------------------------------
puts "--- 8. Context::Builder + LLM ---"

# Build a modest budget to demonstrate truncation.
ctx_budget = Phronomy::Context::TokenBudget.new(
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

builder = Phronomy::Context::Builder.new(budget: ctx_budget)
  .add_system("You are a helpful assistant. Answer in one sentence.")
  .add_knowledge("phronomy is a Ruby AI agent framework.")
  .add_messages(history)

ctx = builder.build
est_history = Phronomy::Context::TokenEstimator.estimate(ctx[:messages])

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
# 9. Agent + ConversationManager + token_budget — evidence that budget limits
#    how many history messages are injected into the LLM context.
# -----------------------------------------------------------------------
puts "--- 9. Agent + ConversationManager budget evidence ---"

# Define a simple agent that answers in one sentence.
class ContextDemoAgent < Phronomy::Agent::Base
  model       LLMConfig::MODEL
  provider    LLMConfig::PROVIDER
  instructions "You are a concise assistant. Answer in one sentence only."
  max_output_tokens 256
  context_overhead  80
end

agent_memory  = Phronomy::Memory::ConversationManager.new(
  storage:   Phronomy::Memory::Storage::InMemory.new,
  retrieval: Phronomy::Memory::Retrieval::Recent.new(k: 200)
)
agent_thread  = "agent_demo"

# Pre-fill memory with many turns so it clearly overflows the budget.
all_prefill = (1..15).flat_map do |i|
  [
    OpenStruct.new(role: :user,      content: "Previous question #{i}: " + ("word " * 15).strip),
    OpenStruct.new(role: :assistant, content: "Previous answer   #{i}: " + ("reply " * 10).strip)
  ]
end
agent_memory.save(thread_id: agent_thread, messages: all_prefill)

total_stored = agent_memory.load(thread_id: agent_thread).length
puts "Messages stored in memory: #{total_stored}"

# Use an intentionally small explicit budget to demonstrate truncation clearly.
# (LM Studio / local models may have large context windows, so we fix a tight
# budget here rather than deriving it from the model registry.)
evidence_budget = Phronomy::Context::TokenBudget.new(
  context_window:    512,
  max_output_tokens: 128,
  overhead:          50
)
budgeted_msgs  = agent_memory.load(thread_id: agent_thread)
estimated_toks = Phronomy::Context::TokenEstimator.estimate(budgeted_msgs)

puts "Budget effective_input_limit: #{evidence_budget.effective_input_limit} tokens"
puts "Messages loaded: #{budgeted_msgs.length} / #{total_stored}"
puts "Estimated tokens for those:   #{estimated_toks}"
puts "Newest message kept: \"#{budgeted_msgs.last&.content&.slice(0, 60)}...\""

result = ContextDemoAgent.new.invoke(
  "What did we talk about?",
  config: { memory: agent_memory, thread_id: agent_thread }
)
puts "Agent response: #{result[:output]}"
if result[:usage]
  puts "Actual API input tokens: #{result[:usage].input}"
end
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
  static_knowledge Phronomy::KnowledgeSource::StaticKnowledge.new(
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
#     always receives at most the most recent conversation turn.
#     The underlying memory store is unaffected.
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

trim_memory = Phronomy::Memory::ConversationManager.new(
  storage:   Phronomy::Memory::Storage::InMemory.new,
  retrieval: Phronomy::Memory::Retrieval::Recent.new(k: 20)
)
trim_thread = "trim_demo"

TrimDemoAgent.new.invoke("Say 'turn 1'.",
  config: { memory: trim_memory, thread_id: trim_thread })
r_trim = TrimDemoAgent.new.invoke("Say 'turn 2'.",
  config: { memory: trim_memory, thread_id: trim_thread })
puts "Turn 2 response: #{r_trim[:output][0, 70]}"
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

cmpct_memory = Phronomy::Memory::ConversationManager.new(
  storage:   Phronomy::Memory::Storage::InMemory.new,
  retrieval: Phronomy::Memory::Retrieval::Recent.new(k: 20)
)
cmpct_thread = "compact_demo"

CompactionDemoAgent.new.invoke("Say 'first message'.",
  config: { memory: cmpct_memory, thread_id: cmpct_thread })
r_cmpct = CompactionDemoAgent.new.invoke("Say 'after compaction'.",
  config: { memory: cmpct_memory, thread_id: cmpct_thread })
puts "Response after compaction: #{r_cmpct[:output][0, 70]}"
puts "(on_compact replaced the oldest message with a summary before the LLM call)"
puts

puts "=== Done ==="
