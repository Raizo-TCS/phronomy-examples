#!/usr/bin/env ruby
# frozen_string_literal: true

# 25 Runtime + EventLoop execution model
#
# The EventLoop is Runtime-owned infrastructure. Application code should use
# public APIs such as Runtime#spawn, Task#map, Workflow#invoke_async and
# Workflow#signal rather than posting internal Event objects directly.

require_relative "../shared/output_validator"
require "phronomy"

puts "=== 25 Runtime + EventLoop execution model ==="
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

pipeline_result = pipeline.invoke({input: "  Hello Runtime  "})
puts pipeline_result.result
puts

puts "--- Pattern 2: async work completes by public Workflow#signal ---"

class FetchState
  include Phronomy::WorkflowContext

  field :url, type: :replace, default: ""
  field :response, type: :replace, default: ""
  field :summary, type: :replace, default: ""
end

fetch_workflow = nil
fetch_workflow = Phronomy::Workflow.define(FetchState) do
  initial :fetching

  state :fetching
  entry :fetching, lambda { |ctx|
    thread_id = ctx.thread_id
    url = ctx.url

    # Runtime owns scheduling. The entry callback itself returns immediately.
    # Task#map is the public completion-composition API.
    Phronomy::Runtime.instance.spawn(name: "example-25-fetch") do
      # Simulate several cooperative work chunks. Real blocking external I/O
      # belongs behind Phronomy's blocking/adaptor boundary, not as a direct
      # blocking call inside a cooperative Runtime task.
      3.times { Phronomy::Runtime.instance.yield }
      "Content for #{url}: Runtime work completed outside the FSM dispatch."
    end.map do |response|
      fetch_workflow.signal(
        thread_id: thread_id,
        event: :fetch_done,
        payload: {response: response}
      )
      response
    end

    nil
  }

  state :summarize, action: lambda { |ctx|
    ctx.merge(summary: "SUMMARY: #{ctx.response[0, 55]}...")
  }

  transition(
    from: :fetching,
    on: :fetch_done,
    to: :summarize,
    action: ->(ctx, event) { ctx.merge(response: event.payload[:response]) }
  )
  transition from: :summarize, to: :__finish__
end

single_result = OutputValidator.validate(
  "async Workflow completes through Workflow#signal",
  check: ->(r) { r.summary.start_with?("SUMMARY:") }
) { fetch_workflow.invoke({url: "https://example.test/document"}) }

puts single_result.summary
puts

puts "--- Pattern 3: several Workflow invocations as Phronomy Tasks ---"

tasks = 3.times.map do |i|
  fetch_workflow.invoke_async(
    {url: "https://example.test/item/#{i}"},
    config: {thread_id: "example-25-#{i}"}
  )
end

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
