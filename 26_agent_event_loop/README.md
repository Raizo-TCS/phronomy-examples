# 26 — Agent async events + Workflow coordination

This example shows how Agent execution participates in Phronomy's Runtime
without exposing the internal EventLoop as an application API.

## Two complementary Agent async surfaces

`Agent#invoke_async` returns a `Phronomy::TaskResult` and an Agent may independently
have an `on_event` listener bound when lifecycle observation is required.

Use the two surfaces for different purposes:

- `on_event` — observe lifecycle detail such as token/tool/terminal event types;
- `TaskResult` — observe the terminal value/failure/cancellation of the operation.

The first section intentionally uses both: lifecycle events are printed while
the returned TaskResult supplies the terminal result to the external caller.

## Agent → Workflow bridge

When a Workflow needs terminal completion, `task_state` starts `invoke_async`
and applies the returned TaskResult's successful value. It does not subscribe to
Agent `:done`. Phronomy correlates that completion to the current state entry and
propagates failure/cancellation; no application callback or completion signal is
needed. Blocking operations and composed TaskResults use the same contract.

The Agent and Workflow remain independently modelled:

- Agent owns model/tool execution, persisted execution state, and context assembly;
- TaskResult represents terminal completion only;
- Workflow owns business-process state;
- `Workflow#signal` remains available for external business events.

The final section shows `CancellationToken.timeout_after` and demonstrates that
timeout is classified as `Phronomy::TimeoutError` / `:timeout`, not as a generic
failure.

Run:

```bash
bundle exec ruby 26_agent_event_loop/run.rb
```
