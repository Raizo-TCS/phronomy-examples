# 25 EventLoop Opt-In Execution Mode

## Purpose

Demonstrates `Phronomy::EventLoop` — the event-driven execution mode that
separates FSM dispatch (single EventLoop thread) from IO work (IO threads).
Three patterns are shown without requiring a running LLM:

1. **Synchronous workflow under EventLoop** — a three-step pipeline (normalize →
   score → format) that runs synchronously through `Phronomy::Workflow`, using
   the same `invoke` API as non-EventLoop mode.
2. **Async IO pattern with named events** — a workflow whose entry action spawns
   a Thread, simulates a 150 ms HTTP round-trip, stores the result in an external
   hash (`FETCH_RESULTS`), then calls `Phronomy::EventLoop.instance.post` to
   fire a `:fetch_done` event back to the EventLoop, which then advances the FSM
   to the next state.
3. **Concurrent workflows sharing one EventLoop** — three invocations of the
   same async workflow run concurrently on the same `EventLoop` instance.
   Because each IO thread sleeps in parallel, total wall-clock time is ~150 ms
   instead of 3 × 150 ms.

## Phronomy Features

| Feature | Class / Module |
|---|---|
| EventLoop global activation | `Phronomy.configure { \|c\| c.event_loop = true }` |
| Event loop singleton | `Phronomy::EventLoop.instance` |
| Posting async events | `Phronomy::EventLoop.instance.post(...)` |
| Named event type | `Phronomy::Event.new(type: :fetch_done, target_id: ..., payload: ...)` |
| Workflow definition | `Phronomy::Workflow.define(StateClass)` |
| Workflow context | `Phronomy::WorkflowContext` |
| Context field types | `field :x, type: :replace` / `type: :append` |
| Entry action on state | `entry :fetching, FETCH_ACTION` |
| Event-gated transition | `transition from: :fetching, on: :fetch_done, to: :summarize` |
| Output validation helper | `OutputValidator.validate(...)` |

## How to Run

```bash
cd /home/raizo-tcs/ruby_ai_agent_framework/phronomy-examples
export PATH="$HOME/.local/share/gem/ruby/3.2.0/bin:$PATH"
bundle exec ruby 25_event_loop/run.rb
```

No LLM server is required. All IO is simulated with `sleep`.

## Expected Output (approximate)

```
=== 25 EventLoop Opt-In Execution Mode ===

--- Pattern 1: Synchronous workflow under EventLoop ---
Input:  '  Hello World  '
Output: >> hello world (score=11) <<
Log:    ["[normalize] start", "[normalize] done", "[score] start", "[score] done", "[format] start", "[format] done"]

--- Pattern 2: Async IO pattern (on: event) ---
URL:     https://example.com/doc
Summary: SUMMARY: Content for https://example.com/doc: Lo...
Elapsed: ~160ms  (IO simulated with 150ms sleep)

--- Pattern 3: Three concurrent async workflows ---
  https://example.com/item/0: SUMMARY: Content for https://example.com/item/0:...
  https://example.com/item/1: SUMMARY: Content for https://example.com/item/1:...
  https://example.com/item/2: SUMMARY: Content for https://example.com/item/2:...
Total elapsed: ~160ms for 3 concurrent fetches
(Each fetch takes ~150ms; sharing one EventLoop keeps total near 150ms)
```

The exact elapsed times will vary, but Pattern 3 should take roughly the same
wall-clock time as a single fetch (~150 ms), demonstrating true concurrency.
