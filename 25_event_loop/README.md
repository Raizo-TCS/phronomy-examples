# 25 — EventLoop / FSMSession execution model

The current Phronomy model is **EventLoop-first**. Application code does not
select a scheduler backend and does not use `Runtime#spawn` for logical async
control flow.

```text
Runtime
  ├─ EventLoop
  │    └─ FSMSession / Workflow FSM dispatch
  ├─ BlockingAdapterPool
  │    └─ unavoidable blocking file / DB / network / external-library I/O
  └─ EventLoop-driven timers

Task / PendingOperation = completion handles
```

## Correct async Workflow pattern

A Workflow entry/transition callback is run-to-completion. If it needs work that
cannot complete immediately:

1. start an asynchronous Phronomy lifecycle (`Agent#invoke_async`,
   `Agent#stream_async`, another Workflow, MultiAgent fan-out), **or** submit a
   genuinely blocking external operation to `Runtime#blocking_io`;
2. return the Workflow context immediately;
3. attach `on_complete` to the returned completion handle;
4. call `Workflow#signal` when the operation settles;
5. carry the result/error in the event payload;
6. let the EventLoop perform the next FSM transition.

This example demonstrates:

- `Runtime#blocking_io.submit`
- completion callbacks via `on_complete`
- `Workflow#invoke_async`
- `Workflow#signal`
- external `Task#wait_result`
- `Diagnostics.snapshot`

It intentionally does **not** use removed scheduler/runtime-task APIs and does
not call `Runtime#event_loop.post` or construct internal `Phronomy::Event`
objects.

Run:

```bash
bundle exec ruby 25_event_loop/run.rb
```
