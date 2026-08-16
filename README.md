# Phronomy Examples

These examples target **Phronomy 0.20.x** through the
shared `Gemfile.phronomy` dependency.

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

```text
Agent durable state ───────┐
                           ├─ Phronomy::Persistence
Workflow workflow_states ──┘
```

Live Agent state remains owned by the live Agent/Activation. Persistence is the
last committed durable representation and recovery source. Workflow
`thread_id` is the durable logical Workflow identity; the Runtime's
`fsm_session_id` is private execution identity.

Start with **29_unified_persistence** for the architecture and
**30_sqlite_persistence** for a real external durable backend.

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

Task = completion handle, not an execution backend
```

Application code composes public APIs such as `invoke_async`, `stream_async`,
`Workflow#signal`, `Task#on_complete`, `Task#map`, and cancellation tokens. It
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

Normal repository use resolves the released 0.19-compatible dependency through
that shared definition:

```bash
./scripts/update_phronomy.sh
./scripts/verify_examples.sh
```

To test every bundle against a specific local checkout, export `PHRONOMY_PATH`
so the same value is available to dependency update and verification:

```bash
export PHRONOMY_PATH=../phronomy
./scripts/update_phronomy.sh
./scripts/verify_examples.sh
```

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

### Human-in-the-loop and execution control

| Example | Focus |
|---|---|
| `04_interrupt_resume` | Workflow wait-state HITL + Agent tool approval + live owner lookup |
| `25_event_loop` | EventLoop/FSMSession + OffloadPool completion events |
| `26_agent_event_loop` | Agent async events → Workflow signal; timeout |
| `23_bounded_parallel` | Bounded child-Agent fan-out |

### Multi-agent

| Example | Focus |
|---|---|
| `05_multi_agent` | Agent-as-tool composition |
| `17_multi_agent_handoff` | Handoff |
| `21_team_coordinator` | Stateful worker assignment |
| `22_shared_state` | Shared Agent state |
| `23_bounded_parallel` | FanOut FSMSession / parallel Orchestrator pattern |

### MCP and integrations

| Example | Focus |
|---|---|
| `08_mcp_tool` | MCP tool |
| `13_mcp_http_tool` | MCP over HTTP |

### Larger applications

| Example | Focus |
|---|---|
| `09_rails_chat` | Rails chat |
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

Then run the repository verification:

```bash
./scripts/verify_examples.sh
```

The SQLite Persistence reference backend has an additional database contract
suite that does not require an LLM:

```bash
cd 30_sqlite_persistence
bundle exec rspec
```

For local Phronomy development, keep `PHRONOMY_PATH` exported while running
dependency update and verification:

```bash
export PHRONOMY_PATH=../phronomy
./scripts/update_phronomy.sh
./scripts/verify_examples.sh
(cd 30_sqlite_persistence && bundle exec rspec)
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
