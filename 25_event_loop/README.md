# 25 EventLoop / FSMSession execution model

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

TaskResult / PendingOperation = completion handles
```

## Correct async Workflow pattern

Declare `task_state(name, start:, apply:)` for a state-owned asynchronous wait.
`start` returns an Agent/Workflow TaskResult, or submits actual blocking I/O to
`Phronomy::Blocking.call_async`. It receives an isolated context snapshot.
`apply` performs the short state update on EventLoop; ordinary guards then route
the updated context. Waiting for the Task consumes no worker.

In this example, expected operation errors are converted into data inside the
blocking operation, preserving the application's failure state. Submission and
cancellation failures propagate through the Workflow TaskResult. No implicit
retry is added. External callers may wait on `Workflow#invoke_async` results.

The example also prints `Diagnostics.snapshot`. External business events can
still use `Workflow#signal`; source completion no longer needs that bridge.

`OffloadPool` is bounded synchronous-work isolation. It is not a scheduler for
logical Workflow execution and does not imply CPU isolation.

The example intentionally does **not** use removed scheduler/runtime-task APIs
and does not call `Runtime#event_loop.post` or construct internal
`Phronomy::Event` objects.

Run:

```bash
bundle exec ruby 25_event_loop/run.rb
```
