# A Workflow waits for a shared Agent across Ruby workers

Each Workflow persists its intended child call in an explicit wait state.
The host dispatches the Agent under a separate claim and later wakes the
parent by Workflow ID and wait revision. The parent reads the child's
committed result; queue messages only identify the call.

For example, X and Y request separate executions of Agent S. S needs human
approval for X. While X waits, worker A serves Y. Y's request remains in the
SQLite inbox until S can accept it. Worker B approves X, resumes its parent,
and is forcibly stopped before the parent delivery is acknowledged. A replays
the delivery and observes the existing receipt. Each parent imports one result.
When X is rejected, its parent receives a durable rejection and the Tool never runs.
Both decisions are exercised with B killed immediately before its result reply
and again in a fresh run after the reply but before the inbox ACK.

## Run

Use the feature checkout implementing both hosted approval and
`Workflow#send_saved_event`. The released 0.31.0 gem predates these APIs.
From this directory on Linux:

```sh
export PHRONOMY_PATH=/absolute/path/to/phronomy
bundle install
bundle exec ruby run.rb
```

The example creates two OS processes and a temporary SQLite database. WebMock
supplies only provider HTTP responses. Example 34 supplies the Agent, Tool,
process harness, inbox and approval handler.

## How the boundary works

- The `WorkflowChild::State` fields identify the shared Agent and one child
  execution. The host derives a unique child slot from the Workflow ID. A
  parent always resumes the same definition and version in these workers.
- Finishing the parent start delivery also inserts its child-dispatch row in
  the same inbox transaction. A terminal child ACK likewise enqueues its
  parent-result notification. Request IDs are deterministic and duplicate
  enqueue attempts must identify the same contents. The host reserves the
  `dispatch/` and `result/` ID prefixes at its submission boundary.
- The inbox serializes each `workflow/X` or `agent/S` target. A dispatch that
  encounters a busy S releases its claim and parks its durable row. An answer
  for S can then run. Its terminal ACK atomically promotes parked rows. Y
  completes using the same request ID without resubmission.
- `WorkflowChild::Handler` verifies the parent wait, revision and exact child
  ID before loading the child's durable result. It calls
  `send_saved_event` under the parent claim. The Workflow saves the imported
  result and the consumed wait revision together. A replay reads that receipt.
- As soon as a worker reports its claim, the supervisor retains the worker
  process handle, request ID, and token. Losing the result reply leaves those
  facts available. On a pipe EOF or broken pipe it briefly waits for that
  exact worker to exit. After reaping, only a still-running parent import
  with the matching token is requeued. The pipe error reaches the caller;
  the next worker can claim the row and observe the saved receipt. A live
  worker retains the claim; the supervisor can later call
  `recover_import(worker)` after confirming exit.

This is an application-defined Workflow wait with a separately hosted Agent.
The scenarios cover completed/rejected child results and failure between import and
ACK under a single live supervisor. Native Agent Tool descendants,
arbitrary `task_state` callbacks, child failure/cancellation routing,
worker loss before the claim is reported, supervisor restart, fleet-wide
fencing, and an uncertain Tool effect need
their own contracts. In particular, a crash before an Agent answer's ACK is
not a signal to repeat the Tool.

See [the acceptance specification](../spec/35_workflow_child_approval.md).
