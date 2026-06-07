# frozen_string_literal: true

require_relative "../shared/llm_config"
require_relative "../shared/output_validator"
require "phronomy"

# ============================================================
# 26 — Agent EventLoop Mode
#
# Demonstrates two patterns for running agents through the EventLoop:
#   Pattern 1 — Agent#invoke  (routes through AgentFSM automatically)
#   Pattern 2 — invoke_async + Task#map embedded inside a Workflow
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
    # invoke_async returns a Task. Task#map transforms the agent result into a
    # WorkflowContext, which FSMSession picks up via the :action_completed path.
    TranslationAgent.new.invoke_async(ctx.query).map do |result|
      ctx.merge(answer: result[:output])
    end
  }
  # invoke_async returns a Task; Task#map transforms the agent result into a
  # WorkflowContext, which FSMSession picks up via the :action_completed path.
  transition from: :translate, to: :done

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
result = OutputValidator.validate(
  "pattern 1: QnA agent answers arithmetic",
  check: ->(r) { r[:output].match?(/\d/) }
) { QnAAgent.new.invoke(question) }
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond) - t0
puts "Q: #{question}"
puts "A: #{result[:output]}"
puts "Elapsed: #{elapsed}ms"
puts

# Pattern 2
puts "--- Pattern 2: Agent as child FSM inside a Workflow ---"
final = OutputValidator.validate(
  "pattern 2: translation workflow completes via EventLoop",
  check: ->(r) { r.status == "done" }
) {
  TranslationWorkflow.invoke(
    { query: 'Translate "hello" to Japanese' },
    config: { thread_id: "26-demo" }
  )
}
puts "Query:  #{final.query}"
puts "Answer: #{final.answer}"
puts "Status: #{final.status}"
