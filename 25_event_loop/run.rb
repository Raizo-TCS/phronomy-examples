#!/usr/bin/env ruby
# frozen_string_literal: true

# 25 EventLoop Opt-In Execution Mode
#
# Demonstrates Phronomy::EventLoop — the event-driven execution mode that
# separates FSM dispatch (single EventLoop thread) from IO work (IO threads).
#
# Three patterns are shown without requiring a running LLM:
#   Pattern 1 — Synchronous actions under EventLoop (same API as sync mode)
#   Pattern 2 — Async IO pattern: entry action spawns a Thread; completion
#               fires a named event back to EventLoop via #post
#   Pattern 3 — Concurrent workflows: three invoke calls share one EventLoop
#               and finish in ~150 ms total (not 3 x 150 ms)

require_relative "../shared/llm_config"
require "phronomy"

# Activate EventLoop mode globally. The invoke / send_event / resume API
# is identical to sync mode — only the execution driver changes.
Phronomy.configure { |c| c.event_loop = true }

puts "=== 25 EventLoop Opt-In Execution Mode ==="
puts

# ── Pattern 1: Synchronous workflow under EventLoop ──────────────────────────

puts "--- Pattern 1: Synchronous workflow under EventLoop ---"

class PipelineState
  include Phronomy::WorkflowContext

  field :input,  type: :replace, default: ""
  field :result, type: :replace, default: ""
  field :log,    type: :append,  default: -> { [] }
end

NORMALIZE = ->(s) {
  s.log << "[normalize] start"
  s.result = s.input.strip.downcase
  s.log << "[normalize] done"
}

SCORE = ->(s) {
  s.log << "[score] start"
  s.result = "#{s.result} (score=#{s.result.length})"
  s.log << "[score] done"
}

FORMAT = ->(s) {
  s.log << "[format] start"
  s.result = ">> #{s.result} <<"
  s.log << "[format] done"
}

sync_app = Phronomy::Workflow.define(PipelineState) do
  initial :normalize
  state :normalize, action: NORMALIZE
  state :score,     action: SCORE
  state :format,    action: FORMAT
  transition from: :normalize, to: :score
  transition from: :score,     to: :format
  transition from: :format,    to: :__finish__
end

result = sync_app.invoke({input: "  Hello World  "})
puts "Input:  '  Hello World  '"
puts "Output: #{result.result}"
puts "Log:    #{result.log.inspect}"
puts

# ── Pattern 2: Async IO pattern ──────────────────────────────────────────────

puts "--- Pattern 2: Async IO pattern (on: event) ---"

class AsyncState
  include Phronomy::WorkflowContext

  field :url,      type: :replace, default: ""
  field :response, type: :replace, default: ""
  field :summary,  type: :replace, default: ""
end

# Shared store for IO results, keyed by workflow thread_id.
# Written by IO threads BEFORE posting :fetch_done;
# read and deleted by SUMMARIZE_ACTION on the EventLoop dispatch thread.
# The EventLoop queue provides the happens-before guarantee — no Mutex needed.
#
# Context safety: the IO thread must not mutate WorkflowContext fields directly
# when EventLoop mode is active (raises WorkflowContextOwnershipError).
# Passing data through an external Hash and using the EventLoop queue as the
# synchronization barrier is the correct pattern for async IO in EventLoop mode.
FETCH_RESULTS = {}

# Entry action for :fetching. Returns immediately after spawning an IO thread.
# The IO thread simulates a 150 ms HTTP round-trip, stores the result in
# FETCH_RESULTS, then posts :fetch_done so the EventLoop can advance the FSM.
FETCH_ACTION = ->(s) {
  url       = s.url
  thread_id = s.thread_id
  Thread.new do
    sleep 0.15                                               # simulate IO
    FETCH_RESULTS[thread_id] = "Content for #{url}: Lorem ipsum dolor sit amet."
    Phronomy::EventLoop.instance.post(
      Phronomy::Event.new(type: :fetch_done, target_id: thread_id, payload: nil)
    )
  end
  # Returns immediately — EventLoop keeps this FSM registered until :fetch_done
}

SUMMARIZE_ACTION = ->(s) {
  response = FETCH_RESULTS.delete(s.thread_id) || ""
  s.summary = "SUMMARY: #{response[0, 40]}..."
}

async_app = Phronomy::Workflow.define(AsyncState) do
  initial :fetching
  state :fetching             # async IO state — no auto-transition
  state :summarize, action: SUMMARIZE_ACTION
  entry :fetching, FETCH_ACTION
  transition from: :fetching,  on: :fetch_done, to: :summarize
  transition from: :summarize, to: :__finish__
end

t0      = Time.now
result  = async_app.invoke({url: "https://example.com/doc"})
elapsed = ((Time.now - t0) * 1000).round

puts "URL:     #{result.url}"
puts "Summary: #{result.summary}"
puts "Elapsed: #{elapsed}ms  (IO simulated with 150ms sleep)"
puts

# ── Pattern 3: Concurrent workflows sharing one EventLoop ────────────────────

puts "--- Pattern 3: Three concurrent async workflows ---"

t0 = Time.now

# Each Thread blocks on its own completion_queue.pop.
# The EventLoop thread dispatches all three FSMs; their IO threads sleep
# concurrently, so total wall-clock time is ~150 ms instead of 3 x 150 ms.
threads = 3.times.map do |i|
  Thread.new { async_app.invoke({url: "https://example.com/item/#{i}"}) }
end

results = threads.map(&:value)
elapsed = ((Time.now - t0) * 1000).round

results.each { |r| puts "  #{r.url}: #{r.summary}" }
puts "Total elapsed: #{elapsed}ms for 3 concurrent fetches"
puts "(Each fetch takes ~150ms; sharing one EventLoop keeps total near 150ms)"
