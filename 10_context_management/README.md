# 10 Context Management

Demonstrates phronomy stateful Agent context management features.
Sections 1-8 run with a live LLM. Section 9 requires no LLM.

## Purpose

Explore how the stateful Agent manages conversation history internally
and how the application can inspect, import, clear, and reset it.

## Phronomy Features

| Section | Feature | API |
|---------|---------|-----|
| 1 | Create a stateful agent | `Agent.create(agent_id:, persistence:)` |
| 2 | Multi-turn conversation | same agent instance retains history |
| 3 | Reload a persisted agent | `Agent.load(agent_id, persistence:)` |
| 4 | Read transcript | `agent.transcript` |
| 5 | `result[:messages]` projection | returned slice, not the storage |
| 6 | Import existing history | `Agent.create(context:)` |
| 7 | Clear LLM transcript | `agent.clear_transcript!` |
| 8 | Full context reset | `agent.reset_context!` |
| 9 | Output / context window DSL | `max_output_tokens`, `context_window` |

> **Note**: `Phronomy::LlmContextWindow::TokenBudget` and `TokenEstimator`
> are `@api private` internal utilities. They appear in the run.rb demo for
> illustration only and are not part of the public API.

## How to Run

```bash
bundle exec ruby 10_context_management/run.rb
```

## Key Files

| File | Description |
|------|-------------|
| `run.rb` | All demonstration sections |
| `../shared/llm_config.rb` | LLM configuration + `apply_phronomy_defaults!` |
