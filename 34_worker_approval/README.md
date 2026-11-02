# Standalone Agent approval across two Ruby workers

One local supervisor feeds the same SQLite inbox to two long-lived Ruby processes. The host serializes deliveries targeting one mutable Agent. Phronomy owns the execution and the pending Tool approval, stored using the SQLite adapter from example 30.

For example, A detaches S at its first approval request. B reloads S and approves that same execution while A serves the independent Agent T. In crash mode the supervisor kills A after durable detach and before the inbox acknowledgement, then reconciles the original claim.

## Run locally

Point Bundler at the Phronomy checkout that implements hosted approval. Installing this example's bundle uses the same dependencies as example 30. Each run uses a fresh temporary database, with provider HTTP responses supplied by WebMock.

For example, from this directory on Linux, run the following commands. The normal and crash cases each print distinct worker PIDs, the completed execution ID and one recorded Tool call.

```sh
export PHRONOMY_PATH=/absolute/path/to/phronomy
bundle install
bundle exec ruby run.rb
```

Run one case with `bundle exec ruby run.rb normal` or `bundle exec ruby run.rb crash`. The published 0.31.0 gem predates these APIs. A development lockfile can contain a local checkout path.

## What each component owns

The inbox persists accepted commands and claims. The handler translates those commands to public Agent APIs. The supervisor controls timing so tests can reproduce an exact crash window.

For example, the initial request is stored with a reserved execution ID before A is dispatched. When A is killed, the supervisor reaps that exact child, verifies its recorded claim, queries the saved approval by Agent and execution ID, and conditionally records the missing ACK. A queued answer then becomes eligible. The supervisor refuses to release a live child. Repeating the same accepted answer does not repeat the Tool call.

- `inbox.rb` and `database.rb` implement delivery using SQLite. One partial unique index protects a target claim.
- `handler.rb` and `conversation.rb` own the Agent calls, approval policy and Tool effect.
- `worker.rb` calls the handler. Its pipe exchanges expose deterministic synchronization points to the supervisor.
- `recovery.rb` reconciles the initial delivery after verified process termination. `run.rb` checks the normal and crash paths.

This example assumes one trusted local supervisor and one approval in the run. It does not attempt network-partition fencing, supervisor restart, shared-child recovery, authentication, or replay of an irreversible Tool effect with unknown outcome. The inbox keeps uncertain inputs for separate resolution.
