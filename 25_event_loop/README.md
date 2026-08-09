# 25 — Runtime + EventLoop execution model

The current Phronomy model is **not an opt-in EventLoop mode**.

The Runtime owns scheduling and its EventLoop. Application code should stay on
the public boundary:

```text
Runtime
  ├─ Task scheduling
  ├─ blocking pools / timers / metrics
  └─ EventLoop
       └─ Workflow FSM dispatch
```

## Correct async Workflow pattern

A Workflow entry/transition callback is run-to-completion. If it needs
asynchronous work:

1. start the work;
2. return `nil` (or a context), **not a Task to be awaited by the action**;
3. when the work completes, call `Workflow#signal`;
4. carry the result in the event payload;
5. let the EventLoop perform the next FSM transition.

The example uses:

- `Runtime#spawn`
- public `Task#map`
- `Workflow#invoke_async`
- `Workflow#signal`
- `Diagnostics.snapshot`

It intentionally does **not** call `Runtime#event_loop.post` or construct
internal `Phronomy::Event` objects.

Run:

```bash
bundle exec ruby 25_event_loop/run.rb
```
