# 26 — Agent async events + Workflow coordination

This example shows how Agent execution participates in Phronomy's Runtime
without exposing the internal EventLoop as an application API.

## Two complementary Agent async surfaces

`Agent#invoke_async` returns a `Phronomy::Task` and an Agent may independently
have an `on_event` listener bound when lifecycle observation is required.

Use the two surfaces for different purposes:

- `on_event` — observe lifecycle detail such as token/tool/terminal event types;
- `Task` — observe the terminal value/failure/cancellation of the operation.

The first section intentionally uses both: lifecycle events are printed while
the returned Task supplies the terminal result to the external caller.

## Agent → Workflow bridge

When a Workflow only needs terminal completion, it does not need to subscribe to
Agent `:done`. The application uses the common completion contract instead:

```text
Workflow entry
  → Agent#invoke_async
  → Phronomy::Task
  → return immediately
  → Task#on_complete
  → Workflow#signal(workflow_instance_id:, event:, payload:)
  → Workflow transition
```

This is the same shape used for other asynchronous producers that return a Task,
such as OffloadPool work or child lifecycle operations.

The Agent and Workflow remain independently modelled:

- Agent owns model/tool execution, persisted execution state, and context assembly;
- Task represents terminal completion only;
- Workflow owns business-process state;
- `Workflow#signal` remains the explicit event ingress into the Workflow FSM.

The final section shows `CancellationToken.timeout_after` and demonstrates that
timeout is classified as `Phronomy::TimeoutError` / `:timeout`, not as a generic
failure.

Run:

```bash
bundle exec ruby 26_agent_event_loop/run.rb
```
