# Example 35: Workflow result import across workers

## Behavior

A parent Workflow persists an explicit child wait. A child completion message
identifies a specific parent wait and Agent execution. The handler checks the
stored facts under an exclusive target claim before applying an event.

For example, X and Y refer to the same mutable Agent S. Worker A detaches S
at X's approval wait, starts Y, then parks Y's child dispatch. B takes X's
answer and commits S's result. The original Y request can then run. A parent
event for Y carrying X's child ID is rejected before acting on Y.

## Acceptance

Run [the example](../35_workflow_child_approval/README.md) using a matching
local core checkout. Both workers use the same SQLite stores and fixed HTTP
fixtures. All assertions must pass:

1. X's accepted call has an execution ID bound to X. An attempt to open Y
   with the same child ID is rejected. Y receives its own child ID.
2. The host schedules child dispatch at parent-start ACK and result notification
   at terminal child ACK, using the same SQLite transaction for each pair.
   Y's dispatch is durably parked and later promoted using the same inbox row.
   X can receive an answer while Y is parked. The wrong approval ID fails
   before acting, while repeated delivery of the identical accepted answer
   returns its existing receipt.
3. Completion before S finishes, or a notification addressed to the wrong
   parent/child pair, does not apply a parent transition. A submitter cannot
   preempt the host's `dispatch/` or `result/` request IDs.
4. On X's committed notification, B is killed before it replies with the
   result, or after the reply but before ACK. The supervisor retains the
   claim before reading the result. A broken pipe or EOF requeues only the
   dead worker's matching parent import. Recovery refuses a live B or an
   obsolete claim. A observes `already_applied`, acknowledges the row,
   and leaves X's saved receipt and import count of one unchanged.
5. Y is still waiting after X's replay and imports its own child result
   exactly once. With X approved, the Tool effect log contains B's PID once.
   With X denied, the durable child and parent both report rejection and the
   Tool effect log is empty. Y completes in both scenarios.

Success prints distinct worker PIDs followed by the two parent import counts,
the Tool call count and the pre-ACK redelivery result. The exercise does not
generalize this recovery window to arbitrary failures during Agent approval.
