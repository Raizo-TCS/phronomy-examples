# 04 — Human-in-the-loop: Workflow wait state and Agent tool approval

This example intentionally shows **two different HITL boundaries**.

## A. Workflow-level approval

The mail workflow reaches `wait_state :awaiting_approval` and remains there until
the application sends the `:approve` event with `Workflow#send_event`.

The asynchronous draft generation uses the normal completion pattern:

```text
DraftAgent#invoke_async
  → Phronomy::Task
  → Task#on_complete
  → Workflow#signal(:draft_completed)
  → wait_state :awaiting_approval
```

The Task represents only terminal completion. Business-process waiting remains a
Workflow concern.

Use this when the approval is part of the **business process state machine**.

## B. Agent tool approval

`PublishReleaseTool` declares:

```ruby
requires_approval true
```

When the model requests that capability, Phronomy authorizes the tool call,
persists the execution as suspended, and returns a `ToolApprovalRequest`.

If the application still holds the live Agent instance, approval is simply an
instance operation:

```ruby
agent.approve(
  execution_id,
  approval_request_id: request.id,
  approved: true
)
```

If a later application boundary has only the `execution_id`, first resolve the
current process's **existing live owner Agent**, then perform the same instance
operation:

```ruby
agent = ReleaseAgent.live_for_execution(execution_id)

agent.approve(
  execution_id,
  approval_request_id: request.id,
  approved: true
)
```

`live_for_execution` is a Runtime-local lookup. It returns the existing live
Agent owner; it does **not** reload Agent or Execution state from Persistence.
After process restart, or from another Ruby process/service replica, the live
owner may not exist and `ExecutionRehydrationRequiredError` is raised until
durable execution rehydration is available.

`execution_id` is also **not an authorization token**. A web/API application
must authorize the caller against its own application identity and approval
policy before resolving and approving the Agent execution.

From an EventLoop callback use `agent.approve_async(...)`; the synchronous
`agent.approve(...)` API is for callers that are allowed to block.

The important distinction is that Workflow waiting and Agent capability
authorization are related HITL concepts, but they are not the same mechanism.

Run:

```bash
bundle exec ruby 04_interrupt_resume/run.rb yes yes
```
