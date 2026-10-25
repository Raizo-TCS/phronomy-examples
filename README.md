# Phronomy Examples

These examples use the published Phronomy `~> 0.31.0` gem through
`Gemfile.phronomy` and all seven lockfiles. It adds explicit schema delivery,
durable transcript Message reads and safe one-shot/child Agent release to structured Agent output,
GeneratorVerifier lifetimes and explicit bounded LM Studio parse-error handling.
The baseline includes the r8 contracts and RubyLLM 2.0 migration.
DX05-A provides owned Agent absence and Team busy errors with saved cause
diagnostics; DX05-D provides Workflow task states;
DX05-E provides application-owned Agent scopes and safe incarnation release.
See [Agent ownership and acceptance](docs/dx05-agent-scope-examples.md) and
[error API changes](ERROR-API.md).

Complete old in-flight Tool executions before upgrading; see the core migration
guide. Local framework development can still select a checkout explicitly with
`PHRONOMY_PATH`.

DX05-C moves example 14's parallel-review completion bookkeeping to the existing
`TaskResult.all_settled` API. Reviewer grouping and partial-failure policy stay in
the application; see the [before/after comparison](docs/dx05-review-composition.md).
DX05-C itself introduces no new core API.

DX05-B routes example 20's notifications through the existing
`OrderedEventDelivery` scope. The application chooses payloads and destinations;
M91 handles ordering and drain outside EventLoop. Saved scan results survive a
final notification failure. See the [before/after comparison](docs/dx05-notification-delivery.md).
DX05-B itself introduces no new core API.

DX05-D migrates 01/03/04/07/14/20/25/26 to `task_state(start:, apply:)`.
Phronomy owns completion correlation and failure delivery; applications own their
operations, result mapping and business events. See the
[before/after and responsibility boundaries](docs/dx05-workflow-task-state.md).
DX05-E adds explicit ownership scopes around these workflows and notification delivery.

Embeddings live in `Phronomy::Embeddings`; loaders and splitters live in
`Phronomy::Documents`. See [r8 unit 5 migration](R8-UNIT5.md) and
[r8 unit 6 migration](R8-UNIT6.md) for the historical migration steps.

CI installs the published RubyGems dependency using the committed lockfiles. No local
checkout or `PHRONOMY_PATH` override is used. To verify a local framework checkout,
export `PHRONOMY_PATH` and run
`scripts/update_phronomy.sh` first.

## DX1 and DX2

Examples 20 and 27 declare their output shape and consume Agent-validated JSON
with `schema_delivery: :none`. Prompt content and business policy stay in the
application; there is no implicit provider fallback, JSON repair or Tool replay.
Examples 09 and 15 read `transcript_messages`; Agent restores the Message values,
while the shared application helper selects visible roles and text.

The new structured executions use AgentExecution format 0.3. Existing format
0.2 records remain readable; old readers explicitly reject the new format.
Do not downgrade a store containing new-format executions. See the core
structured-output guide for the compatibility boundary. The
[0.31 migration notes](https://github.com/Raizo-TCS/phronomy/blob/v0.31.0/docs/migrations/0.31.md)
also describe Agent Tool dispatch through `invoke_async` and release-failure handling.

## Verification scope

LM Studio/gpt-oss PEG parsing remains an unresolved known limitation. The
DX1/DX2 live normal path, streaming, Tool use and history restoration remain
unverified in that environment. Updating to the published gem and passing offline
checks or CI do not establish live LLM acceptance or resolve that provider issue.

`bash scripts/verify_examples.sh` runs the configured LLM and automatically
includes all six trust-pipeline acceptance cases, including approval yes/no/cancel.
Failed or blocked acceptance makes the overall command exit nonzero. Its summary
counts this RSpec suite as one check; the suite output and saved JSON list the six
individual outcomes. See [live acceptance](19_trust_pipeline/README.md#content-fidelity-and-reproducible-live-acceptance).

`bundle exec rspec integration/trust_pipeline_spec.rb --format documentation`
runs only that live suite. It preserves the caller's model/server settings and
records evidence in a fresh `tmp/trust-live-*` directory.

`bash scripts/verify_examples.sh --syntax-only` retains dependency/source
preflight, offline regressions, CLI Ruby syntax checks and the SQLite spec suite.
It explicitly skips the six live trust cases and all four Rails smoke tests,
including their database setup, server startup, health requests and browser
interactions. This mode does not execute CLI examples or call a live LLM, even
when provider credentials are present. Skipped checks are reported as skipped,
not passed; failures in the retained checks still make the command fail.
`--preflight-only` stops after preflight and runs no acceptance tests.

`bash scripts/verify_offline.sh` and ordinary CI run deterministic regressions
with protocol stubs or controlled local HTTP servers. They validate the suite's
success/failure propagation but do not establish acceptance with a real model.

CLI runs retain stdout/stderr and exit/cutoff metadata in `tmp/cli-<example>.*`.
CLI 19 also records LLM requests/responses and periodic Ruby thread stacks.
The existing 240-second outer limit is distinct from SDK request timeouts.
See [wait diagnostics and approval handoff](docs/trust-acceptance-environment.md#remaining-wait-investigation)
for a separate diagnostic run and the evidence needed to resolve a wait.

## LLM token settings

`shared/llm_config.rb` configures RubyLLM and its model registry. Use
`PHRONOMY_MODEL`, `PHRONOMY_PROVIDER`, `PHRONOMY_API_KEY`
and optionally `PHRONOMY_BASE_URL` select the model, provider and endpoint.
The key and URL configure the selected provider's RubyLLM settings. If the
generic key is absent, its provider-specific environment variable is used,
such as `OPENAI_API_KEY`, `AZURE_API_KEY`, or `ANTHROPIC_API_KEY`. Credentials
are never borrowed from another provider. Without an explicit provider, a
custom URL selects OpenAI compatibility; otherwise the model registry selects
the provider. Providers with additional authentication requirements need their
SDK-specific configuration. See [acceptance environment setup](docs/trust-acceptance-environment.md).
`PHRONOMY_CONTEXT_WINDOW` supplies model input metadata to the registry;
unavailable local metadata remains unknown instead of falling back to 8192.
It is not a Phronomy Agent DSL override. Code-review chunking needs known metadata.

`PHRONOMY_MODEL_CAPABILITIES` optionally declares the model's capabilities as a
comma-separated list, for example `function_calling,streaming,structured_output`.
The declaration replaces the selected registry entry's capability list; omitting
it preserves the existing behavior. Empty declarations are rejected. Set it only
from verified model/server capabilities: an OpenAI-compatible URL alone does not
establish native schema support. Supporting schemas and Tools individually does
not guarantee their combination. A server rejection remains an explicit failure.

Capability-only changes preserve a cloud model's registered context window.
With a custom endpoint, unavailable local context metadata remains unknown unless
`PHRONOMY_CONTEXT_WINDOW` supplies an explicit limit.

Agent `max_output_tokens` controls generation only. The old output-reserve setting
and `LLMConfig.apply_phronomy_defaults!` have been removed. Cloud OpenAI uses
RubyLLM 2's default Responses protocol; custom OpenAI-compatible endpoints use
RubyLLM's `:chat_completions` protocol setting.

The repository is organized to show not only what can be built with Phronomy,
but also the architectural boundaries that distinguish it from a thin LLM
wrapper.

## The main architectural axes

### Stateful Agent context

```text
Agent Journal
    ↓
Context candidates
    ↓
Context Policy / token budget
    ↓
LLMInputManifest
    ↓
provider-specific materialization
```

The Agent Journal is canonical state. The provider message list is a
**per-invocation projection**, not the authoritative conversation database.

Start with **10_context_management** for this model.

### Unified durable state

`PersistenceComposition` connects separate domain stores to one neutral
`Persistence` coordinator and Storage backend:

| Domain | Injected component |
|---|---|
| Agent | `stores.agent` |
| Team | `stores.multi_agent` |
| Workflow | `stores.workflow` |

See [r8 unit 3 migration](R8-UNIT3.md) for the source-branch API changes.

Live Agent state remains owned by the single live process-local Agent owner.
Persistence is the last committed durable representation and recovery source.
Workflow `workflow_instance_id` is the durable logical Workflow identity; the
Runtime's `fsm_session_id` is private execution identity.

Start with:

- **29_unified_persistence** for the architecture;
- **30_sqlite_persistence** for the portable external backend contract and
  file-backed durability;
- **09_rails_chat** for a real Agent → LLM → SQLite consumer path;
- **31_postgresql_persistence** for true multi-writer and row-level-lock
  behavior on a server database.

### Runtime and event-driven execution

```text
Runtime
  ├─ EventLoop
  │    └─ FSMSession lifecycle coordination
  │         ├─ Agent
  │         ├─ Workflow
  │         ├─ ToolInvocation
  │         └─ MultiAgent fan-out
  ├─ OffloadPool
  │    └─ synchronous work that must stay off EventLoop
  ├─ EventLoop-driven timers
  └─ metrics / shutdown lifecycle

TaskResult = completion handle, not an execution backend
```

Application code composes public APIs such as `invoke_async`, `stream_async`,
`Workflow#signal`, `TaskResult#on_complete`, `TaskResult#map`, and cancellation tokens. It
does not schedule arbitrary Runtime tasks, select a scheduler/backend, or post
internal Event objects directly.

`OffloadPool` isolates synchronous work that must not execute on the EventLoop.
It is not a logical async scheduler and does not provide CPU isolation or
distributed execution.

Start with **25_event_loop** and **26_agent_event_loop**.

## Dependency management

Every Gemfile reads the Phronomy dependency from one file:

```text
Gemfile.phronomy
```

DX1/DX2 require Phronomy 0.31 or later; 0.30.1 does not expose these APIs.
The shared dependency allows `~> 0.31.0`, and all seven lockfiles select the
published 0.31.0 gem. Keep `PHRONOMY_PATH` unset to verify that dependency:

```bash
unset PHRONOMY_PATH
./scripts/update_phronomy.sh
./scripts/verify_examples.sh
```

For local framework development, set `PHRONOMY_PATH` to an explicit checkout and
repeat the dependency update before verification. Do not commit local core paths
in release lockfiles.

The optional SQL package is consumed from `packages/phronomy-active_record`
through `Gemfile.phronomy_active_record`. Its source and gem-build verification
are included here; publishing the SQL gem is a separate operation. See its
[README](packages/phronomy-active_record/README.md) for explicit schema setup.

`31_postgresql_persistence` is included in dependency updates but its database
suite is run separately because ordinary repository verification must remain
usable without a PostgreSQL server.

## Example map

### Fundamentals

| Example | Focus |
|---|---|
| `01_basic_chain` | Basic runnable chain |
| `02_react_agent` | Agent + tools / ReAct |
| `03_state_graph` | Workflow branching |
| `06_guardrails` | Filter/guard boundary basics |
| `07_tracing` | Structured output + tracing |
| `11_agent_streaming` | Token/tool lifecycle streaming |
| `12_prompt_template` | Prompt templates |
| `16_before_llm_input_hook` | Public pre-materialization context hook |
| `28_filter` | Input/output/tool-result Filters |

### Stateful context, persistence, and trust

| Example | Focus |
|---|---|
| `10_context_management` | Journal → candidates → Policy → Manifest |
| `19_trust_pipeline` | Persistent Knowledge + Generator/Verifier |
| `24_vector_store_dimension` | VectorStore + VectorSearch Agent RAG |
| `29_unified_persistence` | Agent + Workflow unified Persistence / durable identity |
| `30_sqlite_persistence` | ActiveRecord + SQLite external Persistence backend / contract / durability |
| `31_postgresql_persistence` | ActiveRecord + PostgreSQL / true multi-writer / row locking / storage failures |

### Human-in-the-loop and execution control

| Example | Focus |
|---|---|
| `04_interrupt_resume` | Workflow wait-state HITL + Agent tool approval + live owner lookup |
| `25_event_loop` | EventLoop/FSMSession + OffloadPool completion events |
| `26_agent_event_loop` | Agent async events → Workflow signal; timeout |
| `23_bounded_parallel` | Bounded child-Agent fan-out |
| `32_async_composition` | Basic and asynchronously evaluated majority voting with Execution and TaskResult |

### Multi-agent

| Example | Focus |
|---|---|
| `05_multi_agent` | Agent-as-tool composition |
| `17_multi_agent_handoff` | Handoff |
| `21_team_coordinator` | Stateful worker assignment |
| `22_shared_state` | Shared Agent state |
| `23_bounded_parallel` | Execution-backed bounded Orchestrator pattern |

### MCP and integrations

| Example | Focus |
|---|---|
| `08_mcp_tool` | MCP tool |
| `13_mcp_http_tool` | MCP over HTTP |

### Larger applications

| Example | Focus |
|---|---|
| `09_rails_chat` | Rails chat + real Agent/LLM durable SQLite consumer |
| `14_code_review` | Event-driven multi-stage code review pipeline |
| `15_rails_secure_chat` | Rails security/trust boundaries |
| `18_rails_agent_job` | ActiveJob + Agent streaming + ActionCable |
| `20_cve_scanner` | Workflow + Agent async lifecycle + OffloadPool boundary |
| `27_issue_analyzer` | GitHub issue analysis against current Phronomy components |

## Choosing the right multi-agent primitive

These examples intentionally distinguish state from concurrency:

- `21_team_coordinator` — a pool of **stateful worker identities**; queued work
  is assigned sequentially.
- `23_bounded_parallel` — **parallel child-Agent fan-out** with a concurrency
  bound. `max_concurrency` limits active child invocations; it is not a worker
  thread count.
- `19_trust_pipeline` — **Generator/Verifier** quality-control loop.
- `17_multi_agent_handoff` — explicit responsibility transfer.

A worker pool should not be assumed to imply parallel execution.

## Verification

Install/update all bundles first:

```bash
./scripts/update_phronomy.sh
```

Then run the ordinary repository verification:

```bash
./scripts/verify_examples.sh
```

The SQLite Persistence reference backend also has a focused database contract
suite that does not require an LLM:

```bash
cd 30_sqlite_persistence
bundle exec rspec
```

The PostgreSQL Phase B suite requires a PostgreSQL server. For example:

```bash
docker run --rm --name phronomy-postgres \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=phronomy_persistence_test \
  -p 5432:5432 \
  postgres:17
```

Then:

```bash
export PHRONOMY_POSTGRES_URL='postgresql://postgres:postgres@127.0.0.1:5432/phronomy_persistence_test'
./scripts/verify_postgresql_persistence.sh
```

The dedicated PostgreSQL verifier runs the authoritative Persistence contract,
PostgreSQL-specific concurrency/locking/failure specs, and the fresh-pool
durability demonstration.

For local Phronomy development, keep `PHRONOMY_PATH` exported while running
dependency update and verification:

```bash
export PHRONOMY_PATH=../phronomy
./scripts/update_phronomy.sh
./scripts/verify_examples.sh
(cd 30_sqlite_persistence && bundle exec rspec)

# With PostgreSQL available:
./scripts/verify_postgresql_persistence.sh
```

Printing the actually loaded implementation is useful when diagnosing version
or source mismatches:

```bash
bundle exec ruby -e '
  require "phronomy"
  spec = Gem.loaded_specs.fetch("phronomy")
  puts "Phronomy #{Phronomy::VERSION}"
  puts spec.full_gem_path
'
```

## Offline regression gate

Run `bash scripts/verify_offline.sh` after installing the root and SQLite bundles.
It checks removed APIs, all Ruby syntax, executable Handoff/Team/parallel/Workflow
samples with HTTP stubs, and the real SQLite Persistence contract. PostgreSQL
is checked separately by `scripts/verify_postgresql_persistence.sh` and its CI job.
The full verifier also runs these CLI regression tests before the live demos.

`bash scripts/verify_examples.sh --preflight-only` checks all seven loaded
Phronomy dependencies, removed APIs, active documentation and architecture
without starting Rails or calling an LLM. The full verifier follows the same
environment settings as `shared/llm_config.rb`; configure local LLM endpoints
explicitly. If a Rails verification port is already occupied, the check fails
without stopping its current owner. Cleanup stops only servers started by the
verifier.

Chat examples 09 and 15 share a transcript reader that preserves literal user
text, including numbers and JSON, and hides assistant tool-call envelopes with
no displayable content. CI also migrates each app and renders saved conversations
through its real controller and view. To run that check inside either app:
`RAILS_ENV=test bundle exec rails runner ../scripts/verify_chat_history.rb`
(prepare the test database with `RAILS_ENV=test bundle exec rails db:prepare`).

Existing `09_rails_chat` databases require the new coordination-table migration:
`cd 09_rails_chat && bundle exec rails db:migrate`. The migration adds tables;
it does not rewrite existing Agent, Journal, Content, or Workflow records.

The [Persistence failure contract migration](docs/migrations/persistence-failure-contracts.md)
explains the paired core change and domain/backend exception ownership.

## r8 unit 6 contracts

See [the migration notes](R8-UNIT6.md) and
[the local LLM/Tool example](33_llm_tool_contracts/README.md).
