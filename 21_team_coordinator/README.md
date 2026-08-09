# 21 — TeamCoordinator: stateful worker pool

`TeamCoordinator` demonstrates **stateful worker assignment**, not parallel
fan-out.

A coordinator can enqueue work for a pool of Agent instances. The worker
instances retain their own conversation state, and the coordinator chooses a
worker for each queued item. In the current implementation, queued work is
processed sequentially.

That distinction matters:

```text
TeamCoordinator
  → multiple stateful worker identities
  → sequential assignment / reuse
```

If the requirement is **true bounded parallel fan-out**, see
`23_bounded_parallel`, which demonstrates the Orchestrator parallel pattern and
`max_concurrency`.

Use TeamCoordinator when worker identity/state and delegated work queues are the
interesting part of the design. Use the parallel pattern when throughput and
concurrency are the interesting part.
