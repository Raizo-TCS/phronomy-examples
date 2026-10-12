# DX05-D: state-owned asynchronous completion

A Workflow application describes its business operation, the fields changed by
its result, and the next-state decision. It should not reconstruct state-entry
identity or delivery failure handling for every Agent call. Phronomy's new
`task_state` owns that bookkeeping through the Workflow contract.

This candidate builds on examples `751d143` and requires the paired DX05-D core
commit pinned in the root README and all CI workflows. Apply/push core before
starting examples CI. Released core 0.28.0 does not contain this API.

## Before and after

Previously, example 01 captured the Workflow by reference, registered a callback,
created a completion event and error envelope, and extracted that envelope in a
transition action. It now describes the same successful business operation as:

```ruby
task_state :generate,
  start: ->(state) {
    CodeGeneratorAgent.new.invoke_async(
      "Write a Hello World program in #{state.language}. Return code only."
    )
  },
  apply: ->(state, result) { state.merge(output: result.fetch(:output)) }
transition from: :generate, to: :done
```

Phronomy creates the reception before calling `start`, associates it with the
live execution and state entry, and applies success before normal guards. Start,
source and apply errors propagate through the Workflow TaskResult. Cancellation
uses source status; stale/duplicate completion is ignored. Queued automatic
progression is entry-scoped too. Delivery failure is observable instead of
leaving the caller waiting indefinitely. These failure guarantees are stronger
than the old manual examples, so equivalence refers to the business flow, not to
every old failure path.

## Application changes

| Example | Task states and retained application policy |
|---|---|
| 01 basic chain | Generate code; retain prompt/output mapping and reuse across inputs |
| 03 state graph | Evaluate/improve; retain score parsing, threshold and iteration cap |
| 04 interrupt/resume | Draft; retain separate Workflow and Agent-tool approval decisions |
| 07 tracing | Generate code; retain automatic tracing |
| 14 code review | Parallel review, improvement, evaluation; retain reviewer grouping, partial-result selection, warning policy and priority halt |
| 20 CVE scanner | Eight asynchronous scan/follow-up states; retain approvals, decision guards, notification payloads and Job-owned delivery scopes |
| 25 EventLoop | Blocking fetch; retain business-error values and failure state; submission/cancellation failures propagate |
| 26 Agent events | Translation; retain lifecycle observation, execution/journal metadata and timeout classification |

Example 20 removes `start_task_node`, `start_blocking_node`,
`signal_node_result` and `async_event_state`. Only real blocking work stays inside
`Blocking.call_async`. Its business `approve_checks`, `approve_remediation` and
`submit_followup` events remain. Notification scopes from DX05-B are unchanged.

## Responsibility boundaries

C02 Workflow owns state-entry matching, once-only consumption, failure and
restart rules. C13 supplies TaskResult notification. I07 binds C02 to the concrete
FSM and its owner Runtime. Engine receives no task-state policy. C04 keeps Agent
execution and recovery; Rails and CVE policy remain in the application.

`start` receives a snapshot and returns a TaskResult promptly. `apply` is short,
synchronous EventLoop work returning the context type or nil. Ordinary actions
still cannot return Tasks. No worker is occupied just to wait for a source.

A task-state wait is process-local. Completion/ordinary `wait_state` halt saves
still work, and a later process may resume a saved business wait into a new task
state. A snapshot already in a task-state phase cannot safely recreate its
source: `WorkflowTaskResumeError`, code `workflow.task_resume_unsupported`,
requires explicit reconciliation. No automatic replay/retry is introduced.
Parent cancellation stops applying results; it does not physically stop a child
or release an Agent. DX05-E Agent lifetime work remains separate.

## Verification

Root acceptance runs real Agent/Workflow code with HTTP protocol stubs, including
all migrated CLI paths and the full review halt/resume path. The CVE suite keeps
its real Rails Job/notification coverage. The shared SQL task-state contract
checks saved wait-state resume and pending-task rejection through a new pool for
both dialects. A missing PostgreSQL server is a verification prerequisite failure,
not evidence of a passing PostgreSQL run. Apply-time verification must run its
132 tests and reload demo, plus the complete CI matrix.
