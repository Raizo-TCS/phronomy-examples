# frozen_string_literal: true

require_relative "../shared/llm_config"
require_relative "../shared/output_validator"
require "phronomy"

# ============================================================
# 26 — Agent EventLoop Mode
#
# Demonstrates two patterns for running agents through the EventLoop:
#   Pattern 1 — Agent#invoke  (routes through AgentFSM automatically)
#   Pattern 2 — invoke_async with on_event: listener inside a Workflow
#               The entry action signals :translation_completed when done;
#               the transition action copies the result into the context.
# ============================================================

Phronomy.configure do |c|
  c.default_model = LLMConfig::MODEL
end

# ----------------------------------------------------------
# Pattern 1 — simple Q&A agent (no tools)
# ----------------------------------------------------------
class QnAAgent < Phronomy::Agent::Base
  agent_definition id: "example-26-qna-agent", version: 1

  model        LLMConfig::MODEL
  provider     LLMConfig::PROVIDER
  instructions "You are a helpful assistant. Answer concisely."
end

# ----------------------------------------------------------
# Pattern 2 — Translation agent + Workflow
# ----------------------------------------------------------
class TranslationAgent < Phronomy::Agent::Base
  agent_definition id: "example-26-translation-agent", version: 1

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

# translation_workflow is captured by reference so the on_event lambda can
# call signal after Workflow.define returns.
translation_workflow = nil
translation_workflow = Phronomy::Workflow.define(TranslationContext) do
  initial :translate

  state :translate
  entry :translate, ->(ctx) {
    thread_id = ctx.thread_id
    TranslationAgent.new.invoke_async(
      ctx.query,
      on_event: ->(event) {
        next unless event.type == :done
        translation_workflow.signal(
          thread_id: thread_id,
          event: :translation_completed,
          payload: {answer: event.payload[:output]}
        )
      }
    )
    ctx
  }

  state :done, action: ->(ctx) { ctx.merge(status: "done") }

  transition(
    from: :translate,
    on: :translation_completed,
    to: :done,
    action: ->(ctx, event) { ctx.merge(answer: event.payload[:answer]) }
  )
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
  translation_workflow.invoke(
    { query: 'Translate "hello" to Japanese' },
    config: { thread_id: "26-demo" }
  )
}
puts "Query:  #{final.query}"
puts "Answer: #{final.answer}"
puts "Status: #{final.status}"
