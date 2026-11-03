# Example 36 — Native child approval across live workers

## Behavior

The host can hand off the same parent and direct child each time the child
reaches a supported Tool approval wait. Workers share the SQLite Agent and
coordination stores. Each worker owns a separate process, Agent registry and
database connections.

For example, A hands a parent/child pair to B before the child applies a change.
B can finish the child locally or hand the pair to C when the child asks to
publish the applied change. The second approval belongs to the original child
execution and has its own request ID.

## Acceptance

The example verifies ownership at each handoff and records the PID and order
of the resulting Tool effects. Fixed HTTP responses make each approval and
decision reproducible.

For example, in `reject-second`, B accepts the first request and applies
the change. C receives the publish request and rejects it. The effect log
contains only B's application of the change. The child records rejection
and the parent completes with the fixture's response to the empty child output.

Run [the example](../36_native_child_approval/README.md) with a matching local
core checkout. The default command checks the following cases in fresh databases.

| Case | Child outcome | Parent outcome | Ordered Tool effects |
|---|---|---|---|
| `approve` | Completed | Completed | Apply in B |
| `reject` | Rejected | Completed | None |
| `approve-twice` | Completed | Completed | Apply in B, publish in C |
| `reject-second` | Rejected | Completed | Apply in B |

- A releases both Agent instances. B restores the same parent, child, executions
  and first request without a provider call. A's old instances reject operations
  and A can handle unrelated Agent work.
- On the second wait, the parent and child execution IDs still match the first
  handoff. B refuses to detach with the first approval's ID and releases with
  the second ID. C restores the second wait without invoking the provider,
  refuses a replay of the first approval and runs no duplicate Tool. B can
  handle unrelated work while C owns the pair.
- Reading the completed parent again preserves the result and causes no extra
  provider call. Every worker that participated is still alive.

The host orders transfers after release. Supervisor loss, distributed worker
fencing and crash recovery of external Tool effects require host policy.
