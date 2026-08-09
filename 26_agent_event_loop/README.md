# 26 — Agent async events + Workflow coordination

This example shows how Agent execution participates in Phronomy's Runtime
without exposing the internal EventLoop as an application API.

## Agent async contract

`Agent#invoke_async` returns a `Phronomy::Task`.

Its `on_event` callback receives structured lifecycle events. For a normal
non-streaming invocation the terminal event is `:done`; errors, timeout and
explicit cancellation have distinct terminal event types.

The callback itself is delivered through the Runtime/EventLoop machinery.

## Agent → Workflow bridge

The important application pattern is:

```text
Workflow entry
  → Agent#invoke_async
  → return immediately
  → Agent :done event
  → Workflow#signal(thread_id:, event:, payload:)
  → Workflow transition
```

The Agent and Workflow therefore remain independently modelled:

- Agent owns model/tool execution, persisted execution state, and context assembly.
- Workflow owns business-process state.
- the event payload is the explicit hand-off.

The final section shows `CancellationToken.timeout_after` and demonstrates that
timeout is classified as `Phronomy::TimeoutError` / `:timeout`, not as a generic
failure.

Run:

```bash
bundle exec ruby 26_agent_event_loop/run.rb
```
