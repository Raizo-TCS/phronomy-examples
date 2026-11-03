# Example 36 — Native child approval across two live workers

## Behavior

A parent Orchestrator dispatches its registered subagent. The host can move
both executions to a second worker once the child's Tool call reaches its
saved approval wait. Each worker has its own process and Agent registry. Both
workers share the SQLite Agent and coordination stores.

For example, worker A receives a child's approval request, releases the parent
and child together, and hands their IDs to B. B restores the original pending
request. While B has the pair, A completes an independent Agent request.

## Acceptance

Run [the example](../36_native_child_approval/README.md) with a matching local
core checkout and fixed HTTP responses. The default command exercises both
answers to the same scenario, each with a fresh database.

1. A can no longer look up either old Agent in its registry. Trying to resume
   the old parent or approve the old child through A's references fails.
2. B restores the same parent, child, executions and approval request without a
   provider call. A can still operate on a separate Agent.
3. On approval, the Tool records B's PID exactly once and the parent receives
   the child output. On rejection, the Tool records no effect. The child
   records rejection and the parent completes with the fixture's response to
   the missing output.
4. Observing the terminal parent again preserves its result and does not
   repeat a provider call. A and B are both alive at the end of each run.

The example exercises cooperative handoff for one directly dispatched child.
The supervisor sends commands in order. Delivery retries, supervisor loss,
distributed worker fencing and recovery of external Tool effects are separate
host concerns.
