# 20 CVE Scanner

Rails-based CVE analysis example using Phronomy Workflow and Agents.

## Current execution model

Workflow nodes coordinate the scan on Phronomy's EventLoop. Agent `stream_async`
returns a TaskResult; `task_state` applies its result before normal transitions. Shell commands and the synchronous Ubuntu scraper use
`Phronomy::Blocking.call_async` and the bounded OffloadPool. Logical waits for
Agents do not occupy that pool. The application creates no raw Threads for
Workflow orchestration.

Screen notifications use the existing M91 `OrderedEventDelivery` API. Each
initial, approval-resume, follow-up-resume and chat Job opens one
`CveScanner::Notifications` scope. Graph nodes and Agent listeners receive its
publisher explicitly. Only the application adapter knows ScanChannel and Rails;
actual broadcasts run outside EventLoop inside the Rails executor. A Job drains
its notifications before returning, including when it pauses for operator input.
The next Job creates a fresh publisher. Operator-note requests use the same
adapter and drain before enqueueing a chat response.

Ordering applies within each scope, not across concurrent Jobs. Payloads are
plain-data snapshots. The queue capacity is 256 and the batch size is 32; active
batches are separate from queue capacity. The 30-second flush timeout limits
waiting and does not forcibly cancel an in-flight delivery. This is not a durable
queue or an acknowledgement that the browser has received the notification.

Saved done/awaiting state is preserved if the final publish or drain fails.
Business failures remain primary if reporting or status-save also fails. A Chat
Job now re-raises its business failure instead of swallowing it. No automatic
retry is added. Listener overflow is observable as a `StreamCallbackError` with
the original `OrderedEventDelivery::OverflowError` and code in its cause.

See the complete [DX05-B before/after design](../docs/dx05-notification-delivery.md)
for the notification responsibility boundary and failure matrix.
[DX05-D](../docs/dx05-workflow-task-state.md) moves state-owned completion into
`task_state`. Agent scope/unload (DX05-E) remains separate; future cleanup must
follow producer completion and notification drain.

## Main Phronomy features

- `Phronomy::Workflow.define`, `task_state` and business approval events
- Agent `stream_async` and `Phronomy::TaskResult` completion handles
- `Phronomy::Blocking.call_async` for synchronous work
- `Phronomy::Integrations::OrderedEventDelivery` for ordered notifications
- Tool approval and operator wait states
- Follow-up and remediation loops represented as FSM state

## Development and verification

Use the core revision pinned in the root `Gemfile.phronomy` by default. Set `PHRONOMY_PATH` only when testing an explicit local framework checkout, as described in the root README.
From this directory:

```bash
bundle install
bin/rails db:create db:migrate
bin/rails server
```

Run real Rails notification, Job and request acceptance tests without a live LLM:

```bash
export RAILS_ENV=test
export PHRONOMY_MODEL=gpt-4o-mini
export PHRONOMY_BASE_URL=https://example.test/v1
export PHRONOMY_API_KEY=test-only
bundle exec rails db:prepare zeitwerk:check
bundle exec rspec spec/lib spec/jobs spec/requests
```

The 75 tests include 29 DX05-B cases. They use real Agent/Tool/Workflow execution,
Rails and persisted Scan records, with protocol-level HTTP stubs, controlled
shell/scraper results and an ActionCable server transport stub. They check
EventLoop isolation, snapshot/order/drain, overflow, primary-error preservation,
saved-state preservation and fresh publishers on resume. The existing CVE Rails
CI job now runs these tests in addition to boot/eager-load checks.

From the repository root, `bash scripts/verify_offline.sh` covers root specs and
SQLite. `bash scripts/verify_examples.sh` additionally runs the broader example
checks. Its GUI smoke tests use `CVE_SCANNER_MOCK_LLM=1`. Those GUI mocks are
distinct from the real Agent protocol-stub acceptance tests above; neither is
a live LLM or external Cable backend connectivity test.

## Agent lifetime

Each initial/resumed/chat Job owns an Agent scope outside its notification scope. Graph builders receive `agents:` explicitly, and task states materialize Agents asynchronously. Completed children are released after notification drain even at an approval/follow-up halt; the next Job creates its own scope. Saved state contains data, never a scope or live Agent. Cleanup-only failure preserves a saved done/awaiting status.

See [DX05-E scope migration](../docs/dx05-agent-scope-examples.md).

## Validated Agent output

The analyst, remediation and follow-up Agents declare `OUTPUT_SCHEMA` and use
`output_schema:` with `schema_delivery: :none`. The provider receives the existing
prompt and Tools without native schema settings. Agent validates the final output
as strict JSON and returns the frozen value through `result[:output]`.
Token and Tool notifications remain provisional; `chat_turn_done` is published
only after validation succeeds. Invalid JSON, fenced JSON, duplicate keys,
schema mismatches, refusals and incomplete output follow the existing error path.
The application does not repair JSON or replay Tools. Business routing and
operator decisions remain in `ScanGraph`.
