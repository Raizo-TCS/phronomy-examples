# 27 GitHub Issue Analyzer

## Purpose

Fetches GitHub Issues from a repository using the `gh` CLI and classifies each
one on two independent axes using an LLM-backed Phronomy Agent:

- **Axis 1 — Issue Type (WHAT):** the nature of the work.
- **Axis 2 — Component (WHERE):** the current architectural area in Phronomy.

The component taxonomy is aligned with the EventLoop/FSMSession architecture in
current Phronomy. Removed scheduler/task-backend concepts are intentionally not
used as active component categories.

The Agent identifies semantically meaningful `(type, component)` pairs for each
issue — **not** the cross-product of independent type and component lists.

Results are printed in five sections and also written to
`docs/issue_analysis.csv`.

## Current component axis

The current categories include:

- Runtime / EventLoop / Timer
- Engine / FSMSession / FSM
- Cancellation / Deadline
- BlockingAdapterPool / Concurrency
- Agent Execution / Context
- Tool / ToolInvocation
- MultiAgent / FanOut / Handoff
- Workflow / StateStore
- Persistence / ContentStore
- Context Policy / Manifest / LLM Adapter
- RAG / VectorStore
- Tracing / Observability
- Filter / Trust / Approval
- MCP / Transport
- Output Parsing / Prompt
- Public API / Configuration
- Testing / CI
- Cross-cutting / Framework-wide

## Phronomy Features

| Feature | Class / Method | Role |
|---|---|---|
| LLM agent | `Phronomy::Agent::Base` | `IssueClassifierAgent` subclass; classifies batches of issues |
| One-shot invocation | `Phronomy::Agent.run_once` | Creates a fresh Agent for each batch so history does not bleed across batches |
| Runtime architecture | EventLoop / FSMSession | Agent lifecycle coordination is handled by Phronomy; no application runtime backend selection is required |
| Shared LLM config | `LLMConfig::MODEL`, `LLMConfig::PROVIDER` | Provider-agnostic model/provider config from `shared/llm_config.rb` |

There is deliberately no `runtime_backend` configuration. Current Phronomy no
longer exposes the old scheduler/backend selection model.

## How to Run

Prerequisites:

- `gh` installed and authenticated (`gh auth login`)
- an OpenAI-compatible LLM server running (for non-dry-run mode)
- environment variables required by `shared/llm_config.rb`

```bash
bundle exec ruby 27_issue_analyzer/run.rb
bundle exec ruby 27_issue_analyzer/run.rb --open-only
bundle exec ruby 27_issue_analyzer/run.rb --dry-run
```

The target repository is `Raizo-TCS/phronomy` by default. Edit `REPO` in
`run.rb` to analyze another repository.

CSV output:

```text
docs/issue_analysis.csv
```

Section 1 and 2 count unique issues. Section 3 counts semantic
`(type, component)` pairs, so its totals can exceed the number of unique issues.
