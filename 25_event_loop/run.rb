#!/usr/bin/env ruby
# frozen_string_literal: true

# 25 EventLoop / FSMSession execution model
#
# The Runtime owns one EventLoop control plane. Application code should use
# public async APIs and completion events rather than scheduling arbitrary
# Runtime work.

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

puts "--- Pattern 2: blocking I/O completes by Workflow#signal ---"

class FetchState
  include Phronomy::WorkflowContext

  field :url, type: :replace, default: ""
  field :response, type: :replace, default: ""
  field :summary, type: :replace, default: ""
  field :error_message, type: :replace, default: ""
end

fetch_workflow = nil
fetch_workflow = Phronomy::Workflow.define(FetchState) do
  initial :fetching

  state :fetching
  entry :fetching, lambda { |ctx|
    thread_id = ctx.thread_id
    url = ctx.url

    # This block stands in for a genuinely blocking external operation. The
    # worker belongs to Phronomy's bounded BlockingAdapterPool. The Workflow
    # entry itself returns immediately and never waits on the EventLoop thread.
    operation = Phronomy::Runtime.instance.blocking_io.submit do
      sleep 0.05
      "Content for #{url}: blocking I/O completed outside FSM dispatch."
    end

    operation.on_complete do |response, error|
      fetch_workflow.signal(
        thread_id: thread_id,
        event: error ? :fetch_failed : :fetch_done,
        payload: {
          response: response,
          error: error
        }
      )
    end

    ctx
  }

  state :summarize, action: lambda { |ctx|
    ctx.merge(summary: "SUMMARY: #{ctx.response[0, 55]}...")
  }

  state :failed

  transition(
    from: :fetching,
    on: :fetch_done,
    to: :summarize,
    action: ->(ctx, event) { ctx.merge(response: event.payload.fetch(:response)) }
  )

  transition(
    from: :fetching,
    on: :fetch_failed,
    to: :failed,
    action: lambda { |ctx, event|
      error = event.payload[:error]
      ctx.merge(error_message: "#{error.class}: #{error.message}")
    }
  )

  transition from: :summarize, to: :__finish__
  transition from: :failed, to: :__finish__
end

single_result = OutputValidator.validate(
  "blocking I/O resumes Workflow through Workflow#signal",
  check: ->(r) { r.error_message.empty? && r.summary.start_with?("SUMMARY:") }
) { fetch_workflow.invoke({url: "https://example.test/document"}) }

puts single_result.summary
puts

puts "--- Pattern 3: several async Workflow invocations return completion handles ---"

tasks = 3.times.map do |i|
  fetch_workflow.invoke_async(
    {url: "https://example.test/item/#{i}"},
    config: {thread_id: "example-25-#{i}"}
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
  blocking_pool_size
  blocking_pool_active
  blocking_pool_queue_length
  event_loop_lag_last_ms
  event_loop_lag_max_ms
].each do |key|
  puts "#{key}: #{diagnostics[key]}"
end
