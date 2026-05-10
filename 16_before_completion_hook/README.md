# 16 Before-Completion Hook

Demonstrates how `before_completion` hooks let you intercept every LLM call
before it is sent — for logging, parameter overrides, or runtime validation.

## Purpose

Show all three hook levels supported by phronomy:

| Level | Registration | Fires for |
|-------|-------------|-----------|
| Global | `Phronomy.configure { \|cfg\| cfg.before_completion = ... }` | Every agent |
| Class | `before_completion ->(ctx) { ... }` in the agent class body | Instances of that class |
| Instance | `agent.before_completion = lambda { ... }` on an object | That specific instance |

Hooks run in order **global → class → instance**. Each hook receives a
`BeforeCompletionContext` and may return a `Hash` to merge into the LLM params.

## Phronomy Features

| Feature | Usage |
|---------|-------|
| `Phronomy.configure` global hook | Accumulates a call log across all agents |
| Class-level `before_completion` DSL | Locks `temperature: 0.0` on `DeterministicAgent` |
| Instance-level `before_completion` attr | Sets `temperature: 1.0` on one creative instance |
| `BeforeCompletionContext` | `.agent`, `.messages`, `.config`, `.params` accessors |
| Hook return value (Hash) | Merges param overrides into the LLM request |

## How to Run

```bash
bundle exec ruby 16_before_completion_hook/run.rb
```

## Files

| File | Description |
|------|-------------|
| `run.rb` | Entry point — 3 scenarios and a summary |
| `agents.rb` | `LoggingAgent` and `DeterministicAgent` definitions |
