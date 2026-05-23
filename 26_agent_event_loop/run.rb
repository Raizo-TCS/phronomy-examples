# frozen_string_literal: true

require_relative "../shared/llm_config"
require "phronomy"

# ============================================================
# 26 — Agent EventLoop Mode
#
# Demonstrates two patterns for running agents through the EventLoop:
#   Pattern 1 — Agent#invoke  (routes through AgentFSM automatically)
#   Pattern 2 — Agent#run_as_child embedded inside a Workflow
# ============================================================

Phronomy.configure do |c|
  c.event_loop = true
  c.default_model = LLMConfig::MODEL
end

# ----------------------------------------------------------
# Pattern 1 — simple Q&A agent (no tools)
# ----------------------------------------------------------
class QnAAgent < Phronomy::Agent::Base
  model        LLMConfig::MODEL
  provider     LLMConfig::PROVIDER
  instructions "You are a helpful assistant. Answer concisely."
end

# ----------------------------------------------------------
# Pattern 2 — Translation agent + Workflow
# ----------------------------------------------------------
class TranslationAgent < Phronomy::Agent::Base
  model        LLMConfig::MODEL
  provider     LLMConfig::PROVIDER
  instructions "You are a translation assistant. Translate the given text and reply with only the translation."
end

class TranslationContext
  include Phronomy::WorkflowContext

  field :query,  type: :replace, default: ""
  field :answer, type: :replace, default: nil
  field :status, type: :replace, default: "pending"
end

TranslationWorkflow = Phronomy::Workflow.define(TranslationContext) do
  initial :translate

  state :translate
  entry :translate, ->(ctx) {
    TranslationAgent.new.run_as_child(ctx.query, ctx: ctx) { |r| ctx.answer = r[:output] }
  }
  transition from: :translate, on: :child_completed, to: :done

  state :done, action: ->(ctx) { ctx.status = "done" }
  transition from: :done, to: :__finish__
end

# ----------------------------------------------------------
# Run
# ----------------------------------------------------------
puts "=== 26 Agent EventLoop Mode ==="
puts

# Pattern 1
puts "--- Pattern 1: Agent#invoke via EventLoop ---"
question = "What is 2 + 2? Reply with just the number."
t0     = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
result = QnAAgent.new.invoke(question)
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond) - t0
puts "Q: #{question}"
puts "A: #{result[:output]}"
puts "Elapsed: #{elapsed}ms"
puts

# Pattern 2
puts "--- Pattern 2: Agent as child FSM inside a Workflow ---"
final = TranslationWorkflow.invoke(
  { query: 'Translate "hello" to Japanese' },
  config: { thread_id: "26-demo" }
)
puts "Query:  #{final.query}"
puts "Answer: #{final.answer}"
puts "Status: #{final.status}"
