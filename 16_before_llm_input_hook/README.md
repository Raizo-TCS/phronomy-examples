# 16 Before LLM Input Hook

Demonstrates how to intercept and patch the LLM request payload immediately
before it is sent to the model, without modifying the agent class.

## Purpose

Show global, class-level, and instance-level `before_llm_input` hooks and
how `LLMInputPatch` and `LLMInputBuildContext` are used.

## Phronomy Features

| Feature | API | Description |
|---------|-----|-------------|
| Global hook | `Phronomy.configuration.before_llm_input = proc { ... }` | Applied to every agent in the process |
| Class-level hook | `class MyAgent; before_llm_input { ... }; end` | Applied to all instances of the class |
| Instance-level hook | `agent.before_llm_input { ... }` | Applied to one specific agent instance |
| Patch return value | `LLMInputPatch.new(model_config_patch: { temperature: 0.0 })` | Merges patches into the outgoing request |
| Build context | `LLMInputBuildContext` | Carries `agent_id`, `agent_definition_id`, `config`, `call_sequence` |

> **Note**: `before_llm_input` receives an `LLMInputBuildContext` object.
> The raw messages array and `RubyLLM::Chat` are intentionally not exposed.
> Hooks should be used for model config overrides (temperature, max_tokens)
> and logging, not for message manipulation.

## How to Run

```bash
bundle exec ruby 16_before_llm_input_hook/run.rb
```

## Key Files

| File | Description |
|------|-------------|
| `agents.rb` | `LoggingAgent` and `DeterministicAgent` with `before_llm_input` hooks |
| `run.rb` | Demonstrates global, class, and instance hook registration and `LLMInputPatch` |
