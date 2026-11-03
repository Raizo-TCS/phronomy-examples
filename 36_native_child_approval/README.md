# A native child Agent waits for approval across live Ruby workers

A parent Orchestrator dispatches to its declared child through the normal
subagent Tool. When that child needs approval, the worker detaches the
supported parent/child pair locally. The next worker uses the persisted
parent Execution, child slot and approval to resume the same call.

For example, A starts a parent that calls a child through
`dispatch_to_worker`. The child asks to run `apply_request`. A releases
both Agents. B loads the parent and reopens that exact approval. With B
waiting, A rejects an unrelated pending approval and runs a new request
on that same unrelated Agent. Both Ruby processes stay alive.

## Run

Use the Phronomy feature checkout that supports a native child execution ID
on the hosted parent's `detach!`. The released 0.31.0 gem predates this API.
From this directory on Linux:

```sh
export PHRONOMY_PATH=/absolute/path/to/phronomy
bundle install
bundle exec ruby run.rb
```

The default command runs both decisions in fresh SQLite databases. To run
one decision, pass `approve` or `reject`. WebMock fixes the provider's HTTP
replies. The processes, Agent dispatch, SQLite adapter and Tool are real.
Success prints the durable outcomes, the Tool call count and the worker PIDs.

## How the handoff works

At the approval boundary, the application identifies the pair to detach.
Phronomy validates and releases the corresponding local owners. After that
returns, the host sends IDs to B. Each worker uses its own objects and its
own database connections.

1. A receives the child's approval event on the parent's listener. The
   event contains the child execution ID and the approval request ID.
   A calls the hosted parent's `detach!(execution_id: ..., approval_request_id: ...)`.
   Both local registry lookups are now empty.
2. B loads the same Orchestrator with both stores and resumes the exact
   parent execution. The listener reports the original child request. The
   parent resume currently reports `ExecutionRehydrationRequiredError`
   while the child is waiting. B answers using the child execution and
   approval IDs, then resumes the parent to import the child's outcome.
3. A separate approval was already pending in A before the handoff.
   A's old parent and child reject operations. Its unrelated Agent
   continues on its original instance and can process another request.
4. Approval executes the Tool once in B. Rejection records a rejected
   child and executes the Tool zero times. In this native dispatch, the
   rejected child's output is empty; the fixture has the parent respond
   "no child output" and complete. Reading the final parent result again
   causes no additional provider call.

Pipes make the order of host commands explicit. The host transfers
ownership only after A confirms its release. The scenario covers a single
direct native child at a quiescent approval wait. Overlapping delivery
from a second host, a worker crash during the Tool's external effect and
more complex graphs require their own coordination or recovery policy.
B retains the finished parent/child coordination history. Evicting terminal
Agent instances while preserving that history is a separate lifecycle case.
See [the acceptance specification](../spec/36_native_child_approval.md).
