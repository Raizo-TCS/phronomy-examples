# spec/25_event_loop.md

## Purpose

Demonstrate `Phronomy::EventLoop` — the opt-in event-driven execution mode
introduced alongside Phase 2 of the EventLoop architecture. The EventLoop
separates FSM dispatch (single background thread) from IO work (IO threads),
enabling multiple concurrent workflows to share one event loop without
blocking each other.

No LLM is required. IO latency is simulated with `Thread.new + sleep`.

## Phronomy Features Demonstrated

- `Phronomy.configure { |c| c.event_loop = true }` — activates EventLoop mode
  globally; the public `invoke` / `send_event` API is unchanged
- `state :name, action: callable` — shorthand for inline entry action
- Synchronous workflow running under EventLoop (same result as sync mode)
- **Async IO pattern**: entry action spawns an IO thread; on completion the
  thread posts a named event via `Phronomy::EventLoop.instance.post`
- `transition from: :fetching, on: :fetch_done, to: :summarize` — event-driven
  (non-blocking) advancement; no `wait_state` needed
- Concurrent workflows: three `invoke` calls run simultaneously via
  `Thread.new`; all three share one EventLoop and finish in ~150 ms total
  (not 3 × 150 ms), demonstrating the concurrency benefit

## Expected Output (approximate)

```
=== 25 EventLoop Opt-In Execution Mode ===

--- Pattern 1: Synchronous workflow under EventLoop ---
Input:  '  Hello World  '
Output: >> hello world (score=11) <<
Log:    ["[normalize] start", "[normalize] done", ...]

--- Pattern 2: Async IO pattern (on: event) ---
URL:     https://example.com/doc
Summary: SUMMARY: Content for https://example.com/doc...
Elapsed: ~160ms  (IO simulated with 150ms sleep)

--- Pattern 3: Three concurrent async workflows ---
  https://example.com/item/0: SUMMARY: Content for https://example.com/item/0...
  https://example.com/item/1: SUMMARY: Content for https://example.com/item/1...
  https://example.com/item/2: SUMMARY: Content for https://example.com/item/2...
Total elapsed: ~160ms for 3 concurrent fetches
(Each fetch takes ~150ms; sharing one EventLoop keeps total near 150ms)
```

## Implementation Steps

1. `Phronomy.configure { |c| c.event_loop = true }` at startup.
2. Define `PipelineState` with `:input`, `:result`, `:log` fields.
3. Build a 3-state sync workflow (`normalize → score → format`) and invoke it
   to show EventLoop mode works identically to sync mode from the caller's perspective.
4. Define `AsyncState` with `:url`, `:response`, `:summary` fields.
5. Write `FETCH_ACTION`: returns immediately after spawning an IO thread that
   sleeps 150 ms, sets `s.response`, then posts `:fetch_done` back via
   `Phronomy::EventLoop.instance.post(Event.new(type: :fetch_done, target_id: s.thread_id, payload: nil))`.
6. Declare the workflow with `transition from: :fetching, on: :fetch_done, to: :summarize`.
   No `wait_state` — the FSM stays registered in the EventLoop, not returned to the caller.
7. Show concurrency: spawn 3 `Thread.new` blocks each calling `invoke` on the same app.
   Collect results with `threads.map(&:value)` and verify total elapsed ≈ 150 ms.
