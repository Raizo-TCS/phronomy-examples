# DX05-E P6: application-owned Agent scopes

Status: local implementation candidate against core `586674cac5422f945c8aeb33c2567c545a729acf`.
The API is unreleased. This unit changes examples only; application-time CI and
PostgreSQL acceptance are still required.

## Problem and outcome

A long-running application needs to say when it has finished using an Agent.
A conversation ID and its saved history can outlive the in-process object.
Previously, repeated reviews and Rails requests created or loaded Agents without
a matching end to their live ownership. Adding manual release in every return
and rescue path would put lifecycle coordination into application code.

The application now declares an operation with `Phronomy::Agent.open_scope` and
acquires Agents through that scope. Phronomy releases safely owned incarnations
at exit while preserving Agent roots, Journals, transcripts, knowledge and
application-owned storage pools. Scope is not a transaction, request lock,
automatic retry, cancellation group or durable message queue.

## Responsibility and dependency boundaries

| Owner | Responsibility |
|---|---|
| Application | Choose operation boundaries, Agent class/ID, shared Store, payloads, retry and business status |
| C04 Agent scope | Own newly materialized incarnations, await a returned TaskResult, attempt safe release of each owned Agent, preserve primary failures |
| C02 Workflow | Own task-state progress and result application; the application injects the Agent scope into start callbacks |
| C13 Execution / C01 Engine | Existing completion and physical work semantics; no new scheduler or blocking EventLoop work |
| M91 OrderedEventDelivery | Existing ordered buffering and drain; no knowledge of Rails, scan status or Agent ownership |
| C07 Storage | Existing neutral transactions and resources; no Agent- or Rails-specific release policy |

Core source, RBS and Contract dependency pairs are unchanged from P5.
Scopes remain in application closures, never in Workflow state, session storage,
global variables or thread-local state. The session retains only an Agent ID.
A scope does not adopt an Agent owned by another scope or a legacy live owner.

## Acquisition before and after

Before (a Rails request, with no end to the incarnation's ownership):

```ruby
agent = ChatAgent.load(agent_id, persistence: PhronomyStore.persistence)
result = agent.invoke(content)
render json: {reply: result[:output]}
```

After (the same request operation and saved conversation):

```ruby
result = Phronomy::Agent.open_scope do |agents|
  agent = agents.load(ChatAgent, agent_id, persistence: PhronomyStore.persistence)
  agent.invoke(content)
end
render json: {reply: result[:output]}
```

The added block is useful because all normal and exceptional exits have one
owner. `close!` changes durable lifecycle state and `purge!` destroys saved data;
neither replaces scope cleanup.

Before (an Agent created from a Workflow task-state start):

```ruby
start: ->(snapshot) { CodeGeneratorAgent.new.invoke_async(prompt) }
```

After (asynchronous materialization and invocation):

```ruby
start: ->(snapshot) {
  agents.create_async(CodeGeneratorAgent).flat_map { |agent| agent.invoke_async(prompt) }
}
```

The containing CLI/request opens the scope and injects it into the Workflow
definition. `create_async` keeps Store work off EventLoop, while `flat_map`
composes the invocation without a worker waiting for the LLM.
Synchronous `create/load/open_scope` must not run on EventLoop.

## Notification completion before Agent release

The following complete application helper is the common entry for initial,
approved and follow-up scan Jobs. The application still owns status and
persistence policy; core receives no Rails or scan-model dependency.

```ruby
def self.with_scan(scan_id)
  Phronomy::Agent.open_scope do |agents|
    CveScanner::Notifications.open(scan_id: scan_id) do |notifications|
      scan = nil
      payload = begin
        scan = Scan.find(scan_id)
        state = yield scan, notifications, agents
        persist_state(scan, state) if state
      rescue StandardError
        record_failure(scan)
        raise
      end

      # Outside the business/persistence rescue: a delivery error must not
      # overwrite a successfully saved done/awaiting status.
      notifications.publish(payload) if payload
    end
  end
end
```

The nested scopes establish: produce events and persist the business result,
drain accepted notifications, then release Agent incarnations. At an approval
halt, completed children can be released; the next Job restores plain Workflow
state and uses fresh scopes. A suspended Agent still awaiting its own approval
must remain owned through approval and original invocation completion (example 04).

Before P6, this helper contained only the notification scope and yielded
`scan, notifications`. It now adds the outer Agent scope and yields the third
argument `agents`. Notification payloads and the business/status decision remain
in the same application components.

## Migration inventory

| Application | Ownership unit |
|---|---|
| 01 basic chain, 03 state graph, 07 tracing | CLI Workflow lifetime; async children belong to the supplied scope |
| 04 interrupt/resume | Separate Workflow and Agent demonstrations; Agent approval keeps one scope until the original invocation resolves |
| 05 Agent-as-Tool | Each outer validation attempt and each application-owned nested Agent call |
| 09 / 15 Rails conversations | Each create/read/message/clear request; session ID and shared Store survive |
| 14 review pipeline | One complete review, including priority selection/resume; the next review reloads the improver's saved history |
| 15 summary | Request scope injected into the summary task state |
| 18 Rails Agent Jobs | One Job including final delivery; streaming delivery is the inner scope |
| 20 CVE Jobs | One initial/resumed/chat Job; nested reference summarization owns a separate local scope |
| 26 Agent EventLoop | Each independent demonstration; the Workflow gets an explicit scope |
| 27 issue analyzer | Each issue batch; new history and released incarnation per batch |
| 32 async composition | Agent scope encloses creation and complete majority-result composition |
| 30 / 31 SQL | Shared lifecycle acceptance now runs as part of each normal backend spec suite |

This is an ownership review, not a blanket replacement of every `new` or `load`.
Remaining examples with a bounded process lifetime demonstrate other APIs
(02/06/08/10/11/12/13/16/24/28/29/33). Their fixed Agent set is intentionally
retained for that demonstration. Persistent/recovery examples demonstrate
live-owner identity and explicit durable lifecycle operations. Tool, Team,
Handoff and evaluator objects constructed by framework-managed composition
(17/19/21/22/23) must not be adopted or forcibly released by an unrelated scope.
25 contains no application-owned Agent lifecycle to migrate. Existing tests'
explicit constructors are not long-lived application entry points.

The scope is usable in other applications without requiring this pattern for
a deliberately process-lived owner. Keeping an owner for such a purpose must
remain an explicit application decision.

## Behavior retained and deliberate changes

Review grouping, chunk order, partial-success warnings, prompts, guardrail
policies, CVE payloads, saved approval/resume fields and application retry
policies are preserved. Review scopes retain the improver's durable identity
but not its old Ruby object or listener.

Two user-visible differences are deliberate:

1. Concurrent Rails requests targeting an already-owned conversation return
   HTTP 409. They do not share a live incarnation or change its listener, and
   do not introduce automatic retries.
2. The summary graph uses a task state instead of a listener-produced
   `summary_done` signal. It waits for a final result and propagates failure to
   the controller; errors no longer masquerade as an empty successful summary.

The root bundle tests the actual Agent, Store and Workflow with protocol-level
HTTP responses, while Rails routing/rendering are doubled. The separate Rails
history runner exercises real requests/views, without resetting Runtime
between requests. CVE acceptance runs inside the real Rails application.

## Failure policy

| Situation | Outcome |
|---|---|
| Business success and safe cleanup | Return the result; history and shared pool remain |
| Business failure and cleanup failure | Preserve the original exception; report cleanup diagnostics with Agent IDs |
| Business success but cleanup failure | Raise `Agent::ScopeCleanupError` with result/failures; no automatic rerun |
| Final delivery fails after saving done/awaiting | Preserve saved state; propagate delivery failure |
| Cleanup fails after a successful final notification | No second error notification; caller receives cleanup failure |
| Another request owns the Agent | HTTP 409; existing owner and session identity are unchanged |
| Parent result cancelled/timed out while child work remains | Unsafe unload is refused; scope does not claim physical completion or silently cancel children |

In example 32, `Execution.open_scope` groups cancellation/deadline behavior;
`Agent.open_scope` manages incarnation ownership. They are distinct. For an
in-flight child, an operation may leave a live owner after fail-closed cleanup.
The caller must observe the original work/cleanup diagnostics and arrange an
appropriate later release. Do not retry a successful business side effect just
because cleanup failed.

## Acceptance and application gates

Added regression coverage checks request reload/history, ownership conflicts,
request failure, summary success/failure, repeated improver reload, Job delivery
before release, cleanup-only failure, CVE halt/resume and double failure.
The prior P5 four-case SQL acceptance is now `shared/agent_scope_contract.rb`,
included by both SQL suites: fresh-pool reload preserves saved revisions and
closed lifecycle, opaque retention blocks unloading, Store failure preserves
the original owner, and async scope cleanup leaves the pool usable.

Run with `PHRONOMY_PATH` set to the reviewed core checkout:

```bash
bundle install
bash scripts/verify_offline.sh
cd 20_cve_scanner
RAILS_ENV=test PHRONOMY_MODEL=gpt-4o-mini \
  PHRONOMY_BASE_URL=https://example.test/v1 PHRONOMY_API_KEY=test-only \
  bundle exec rspec spec/lib spec/jobs spec/requests
cd ../31_postgresql_persistence
bundle install
PHRONOMY_POSTGRES_URL=postgresql://... bundle exec rspec
PHRONOMY_POSTGRES_URL=postgresql://... bundle exec ruby run.rb
```

Use the package's `verification.json` for measured local counts and unexecuted
gates. PostgreSQL and remote CI results must be supplied at application time;
previously reported P5 successes are not P6 test results. Publication still
requires updating the examples dependency to the released core version.
