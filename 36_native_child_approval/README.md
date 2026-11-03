# A native child Agent waits for approval across live Ruby workers

A parent Orchestrator dispatches to its registered subagent. At each supported
child approval wait, the current worker can release both local Agent instances.
The next worker uses the shared SQLite stores to restore the same parent execution,
child execution and pending approval.

For example, A dispatches a child that needs permission to apply and then publish
a change. A releases the pair before either Tool runs. B restores the pair,
approves `apply_request` and releases both Agents when the child asks to publish.
C restores that second request. B serves an unrelated request while C owns the pair.

## Run

Run the example with a Phronomy checkout that provides
`MultiAgent::Orchestrator#approve_hosted_child`. Each scenario starts fresh
worker processes and a new SQLite database. WebMock supplies the provider's HTTP
responses. The workers, persistence adapter, native dispatch and Tools run in Ruby.
The example's version 2 parent definition declares a child with both Tools.

For example, from this directory on Linux:

```sh
export PHRONOMY_PATH=/absolute/path/to/phronomy
bundle install
bundle exec ruby run.rb
```

The default command runs all four scenarios. To select one, pass its name,
for example `bundle exec ruby run.rb reject-second`. The output includes
the child and parent outcomes, the Tool call count and the worker PIDs.

| Scenario | Decision in B | Decision in C | Effects recorded |
|---|---|---|---|
| `approve` | Approve the only request | | B applies |
| `reject` | Reject the only request | | None |
| `approve-twice` | Approve the first request | Approve the second request | B applies, C publishes |
| `reject-second` | Approve the first request | Reject the second request | B applies |

## How the handoff works

The host keeps exclusive ownership of the pair until its current worker confirms
release. Each recipient reopens the saved pair and checks the approval's identity
before acting. The parent and child execution IDs travel through each handoff.
The approval request ID identifies one decision within the child execution.

For example, in `approve-twice`:

1. A receives the child's `apply_request` approval event on the parent's listener
   and passes its execution and request IDs to the hosted parent's `detach!`.
   Both Agents leave A's local registry.
2. B loads the parent with both stores and resumes its execution. The listener
   emits the saved approval. The parent resume reports
   `ExecutionRehydrationRequiredError` while the child remains unfinished.
   B calls `parent.approve_hosted_child` with the accepted request's IDs.
3. B executes `apply_request`. When the child requests `publish_request`, B
   passes the **new** approval request ID to the answer handle's `detach!`.
   The host delivers this second wait to C after B confirms release.
4. C restores the pair at `publish_request` without running `apply_request`
   again. C refuses a replay of the first approval. It approves publication
   and resumes the parent to import the child's
   recorded result. The effect log records B for the first Tool and C for
   the second. All three workers are still alive.

If a worker rejects a request, the child records rejection. In this example
the parent receives empty child output and completes with the fixture's reply,
"no child output". Reading the terminal parent again makes no provider call.

Pipes serialize host commands. The example covers a single directly dispatched
child at a committed approval wait. The host owns overlapping delivery and
crash recovery, including reconciliation of uncertain external effects.
The stores retain the finished parent/child coordination history.

See [the acceptance specification](../spec/36_native_child_approval.md).
