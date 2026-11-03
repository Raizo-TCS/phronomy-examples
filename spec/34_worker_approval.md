# Example 34: Standalone Agent approval across workers

## Purpose

Show two long-lived Ruby workers on one Linux host handing over a standalone
Agent at its first durable Tool approval wait. The application owns delivery
claims and deduplication; Phronomy owns Agent execution and approval facts.

## Demonstrated APIs

- `Agent::ReservedExecution` and `Agent#start_hosted`
- `Agent::HostedInvocation#on_complete` and `#detach!`
- `Agent::Store#standalone_approval_wait`
- Existing `Agent.load`, approval and unload operations
- The optional ActiveRecord persistence package, using SQLite

The core contract tests also cover `HostedInvocation#wait_result`; this example
does not call that method directly.

## Setup and implementation

1. Select a local core checkout implementing hosted approval through
   `PHRONOMY_PATH`. Published v0.31.0 does not provide these APIs.
2. Install the bundle described in [the example README](../34_worker_approval/README.md).
3. Create a fresh SQLite database and two independent worker processes.
4. Store the initial delivery with a reserved execution ID and an exclusive claim.
5. Let worker A detach Agent S at its persisted approval wait. In the normal case,
   worker B resumes S while A handles independent Agent T.
6. In the crash case, reap the exact worker A child after detach but before ACK,
   validate its original claim token and durable wait, then conditionally repair ACK.
7. Apply the queued answer in B, validate completion, and release all resources.

Provider HTTP responses are deterministic WebMock fixtures. No live LLM request
is made, and this example does not establish live-provider acceptance.

## Expected output and assertions

`bundle exec ruby run.rb` prints one `normal:` and one `crash:` line. Each records
separate A/B process IDs, the completed execution ID and `Tool calls=1`, then exits
zero. Both cases assert same-execution completion and one Tool effect. The normal
case checks reuse of A for T. The crash case rejects a wrong claim and verifies
idempotent reconciliation after confirmed process termination. Resending an answer
with the same request ID and identical content does not execute the Tool again.

## Limits

The supervisor stays alive on one trusted host. Multi-host fencing, supervisor
restart, parent Workflow/shared-child transfer, authentication and uncertain
external Tool side effects are outside this example's acceptance scope.
