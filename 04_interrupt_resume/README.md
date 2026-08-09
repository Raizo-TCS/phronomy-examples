# 04 — Human-in-the-loop: Workflow wait state and Agent tool approval

This example intentionally shows **two different HITL boundaries**.

## A. Workflow-level approval

The mail workflow reaches `wait_state :awaiting_approval` and remains there until
the application sends the `:approve` event with `Workflow#send_event`.

Use this when the approval is part of the **business process state machine**.

## B. Agent tool approval

`PublishReleaseTool` declares:

```ruby
requires_approval true
```

When the model requests that capability, Phronomy authorizes the tool call,
persists the execution as suspended, and returns a `ToolApprovalRequest`.
The application can inspect only its safe parameters/facts, then resume the same
execution with:

```ruby
agent.approve(
  execution_id,
  approval_request_id: request.id,
  approved: true
)
```

Use this when approval protects a **tool side effect**.

The important distinction is that Workflow waiting and Agent capability
authorization are related HITL concepts, but they are not the same mechanism.

Run:

```bash
bundle exec ruby 04_interrupt_resume/run.rb yes yes
```
