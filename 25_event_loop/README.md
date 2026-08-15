# 25 — EventLoop / FSMSession execution model

The current Phronomy model is **EventLoop-first**. Application code does not
select a scheduler backend and does not use `Runtime#spawn` for logical async
control flow.

```text
Runtime
  ├─ EventLoop
  │    └─ FSMSession / Workflow FSM dispatch
  ├─ OffloadPool
  │    └─ synchronous work that must stay off EventLoop
  └─ EventLoop-driven timers

Task / PendingOperation = completion handles
```

## Correct async Workflow pattern

A Workflow entry/transition callback is run-to-completion. If it needs work that
cannot complete immediately:

1. start an asynchronous Phronomy lifecycle (`Agent#invoke_async`,
   `Agent#stream_async`, another Workflow, MultiAgent fan-out), **or** submit a
   synchronous external operation that must stay off EventLoop to
   `Runtime#offload`;
2. return the Workflow context immediately;
3. attach `on_complete` to the returned completion handle;
4. call `Workflow#signal` when the operation settles;
5. carry the result/error in the event payload;
6. let the EventLoop perform the next FSM transition.

This example demonstrates:

- `Runtime#offload.submit`
- completion callbacks via `on_complete`
- `Workflow#invoke_async`
- `Workflow#signal`
- external `Task#wait_result`
- `Diagnostics.snapshot`

`OffloadPool` is bounded synchronous-work isolation. It is not a scheduler for
logical Workflow execution and does not imply CPU isolation.

The example intentionally does **not** use removed scheduler/runtime-task APIs
and does not call `Runtime#event_loop.post` or construct internal
`Phronomy::Event` objects.

Run:

```bash
bundle exec ruby 25_event_loop/run.rb
```
