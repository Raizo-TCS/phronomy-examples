#!/usr/bin/env ruby
# frozen_string_literal: true

# 25 EventLoop / FSMSession execution model
#
# The current Phronomy model is **EventLoop-first**. Application code does not
# select a scheduler backend or use removed runtime task/scheduler APIs for
# logical async control flow.

require_relative "../shared/output_validator"
require "phronomy"

puts "=== 25 EventLoop / FSMSession execution model ==="
puts

puts "--- Pattern 1: run-to-completion Workflow actions ---"

class PipelineState
  include Phronomy::WorkflowContext

  field :input, type: :replace, default: ""
  field :result, type: :replace, default: ""
end

pipeline = Phronomy::Workflow.define(PipelineState) do
  initial :normalize

  state :normalize, action: lambda { |ctx|
    ctx.merge(result: ctx.input.strip.downcase)
  }

  state :format, action: lambda { |ctx|
    ctx.merge(result: ">> #{ctx.result} <<")
  }

  transition from: :normalize, to: :format
  transition from: :format, to: :__finish__
end

pipeline_result = pipeline.invoke({input: "  Hello EventLoop  "})
puts pipeline_result.result
puts

puts "--- Pattern 2: blocking I/O completes through task_state ---"

class FetchState
  include Phronomy::WorkflowContext

  field :url, type: :replace, default: ""
  field :response, type: :replace, default: ""
  field :summary, type: :replace, default: ""
  field :error_message, type: :replace, default: ""
end

fetch_workflow = Phronomy::Workflow.define(FetchState) do
  initial :fetching

  task_state :fetching,
    start: ->(snapshot) {
      # Only actual blocking I/O occupies a bounded worker. Expected operation
      # errors become application data; admission/cancellation failures propagate.
      Phronomy::Blocking.call_async do
        sleep 0.05
        {response: "Content for #{snapshot.url}: blocking I/O completed outside FSM dispatch."}
      rescue => error
        {error_message: "#{error.class}: #{error.message}"}
      end
    },
    apply: ->(state, outcome) { state.merge(outcome) }

  state :summarize, action: ->(state) {
    state.merge(summary: "SUMMARY: #{state.response[0, 55]}...")
  }
  state :failed

  transition from: :fetching, to: :failed,
    guard: ->(state) { !state.error_message.empty? }
  transition from: :fetching, to: :summarize
  transition from: :summarize, to: :__finish__
  transition from: :failed, to: :__finish__
end

single_result = OutputValidator.validate(
  "blocking I/O advances Workflow through task_state",
  check: ->(r) { r.error_message.empty? && r.summary.start_with?("SUMMARY:") }
) { fetch_workflow.invoke({url: "https://example.test/document"}) }

puts single_result.summary
puts

puts "--- Pattern 3: several async Workflow invocations return completion handles ---"

tasks = 3.times.map do |i|
  fetch_workflow.invoke_async(
    {url: "https://example.test/item/#{i}"},
    config: {workflow_instance_id: "example-25-#{i}"}
  )
end

# Blocking waits are fine here because this is the external CLI caller, not an
# EventLoop callback. EventLoop code must continue by events instead of waiting.
results = tasks.map(&:wait_result)

results.each do |result|
  puts "  #{result.url} -> #{result.summary}"
end
puts "Completed 3 async Workflow invocations."
puts

puts "--- Runtime diagnostics ---"
diagnostics = Phronomy::Diagnostics.snapshot

%i[
  offload_pool_size
  offload_pool_active
  offload_pool_queue_length
  event_loop_lag_last_ms
  event_loop_lag_max_ms
].each do |key|
  puts "#{key}: #{diagnostics[key]}"
end
