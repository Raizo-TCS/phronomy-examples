# Phronomy Examples

Examples for **Phronomy 0.17.x**.

The repository is organized to show not only what can be built with Phronomy,
but also the architectural boundaries that distinguish it from a thin LLM
wrapper.

## The two main architectural axes

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

### Runtime and event-driven execution

```text
Runtime
  ├─ Tasks / schedulers / blocking pools / metrics
  └─ EventLoop
       ├─ Workflow FSM dispatch
       └─ Agent lifecycle events
```

Application code composes public APIs such as `invoke_async`,
`Workflow#signal`, `Task#map` and cancellation tokens; it
does not need to post internal Event objects.

Start with **25_event_loop** and **26_agent_event_loop**.

## Dependency management

Every Gemfile reads the Phronomy dependency from one file:

```text
Gemfile.phronomy
```

Normal released-gem use:

```bash
bundle install
./scripts/update_phronomy.sh
```

Test every bundle against a local checkout:

```bash
PHRONOMY_PATH=../phronomy ./scripts/update_phronomy.sh
```

When the target Phronomy version changes, edit **only `Gemfile.phronomy`** and
run the update script to regenerate each bundle's lockfile.

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

### Stateful context and trust

| Example | Focus |
|---|---|
| `10_context_management` | Journal → candidates → Policy → Manifest |
| `19_trust_pipeline` | Persistent Knowledge + Generator/Verifier |
| `24_vector_store_dimension` | VectorStore + VectorSearch Agent RAG |

### Human-in-the-loop and execution control

| Example | Focus |
|---|---|
| `04_interrupt_resume` | Workflow wait-state HITL + Agent tool approval |
| `25_event_loop` | Runtime-owned EventLoop and async Workflow pattern |
| `26_agent_event_loop` | Agent async events → Workflow signal; timeout |
| `23_bounded_parallel` | Bounded parallel fan-out |

### Multi-agent

| Example | Focus |
|---|---|
| `05_multi_agent` | Agent-as-tool composition |
| `17_multi_agent_handoff` | Handoff |
| `21_team_coordinator` | Stateful worker assignment |
| `22_shared_state` | Shared Agent state |
| `23_bounded_parallel` | Parallel Orchestrator pattern |

### MCP and integrations

| Example | Focus |
|---|---|
| `08_mcp_tool` | MCP tool |
| `13_mcp_http_tool` | MCP over HTTP |

### Larger applications

| Example | Focus |
|---|---|
| `09_rails_chat` | Rails chat |
| `14_code_review` | Multi-stage code review pipeline |
| `15_rails_secure_chat` | Rails security/trust boundaries |
| `18_rails_agent_job` | ActiveJob + Agent streaming + ActionCable |
| `20_cve_scanner` | CVE analysis application |
| `27_issue_analyzer` | GitHub issue analysis |

## Choosing the right multi-agent primitive

These examples intentionally distinguish state from concurrency:

- `21_team_coordinator` — a pool of **stateful worker identities**; queued work
  is assigned sequentially.
- `23_bounded_parallel` — **parallel fan-out** with a concurrency bound.
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

For local Phronomy development:

```bash
PHRONOMY_PATH=../phronomy ./scripts/update_phronomy.sh
./scripts/verify_examples.sh
```

Printing the actually loaded implementation is useful when diagnosing version
mismatches:

```bash
bundle exec ruby -e '
  require "phronomy"
  spec = Gem.loaded_specs.fetch("phronomy")
  puts "Phronomy #{Phronomy::VERSION}"
  puts spec.full_gem_path
'
```
