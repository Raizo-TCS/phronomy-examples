# Spec: 16_before_completion_hook

## Purpose

Demonstrate how `before_completion` hooks intercept every LLM call and can
inspect context, log metadata, accumulate usage counters, or override model
parameters — without touching the core agent logic.

## Phronomy Features Demonstrated

| Feature | Usage |
|---------|-------|
| `Phronomy.configure` global hook | Accumulates token usage across all calls |
| Class-level `before_completion` DSL | Logs model + message count for each agent class |
| Instance-level `before_completion` attr | Overrides temperature for a specific instance |
| `BeforeCompletionContext` | `.agent`, `.messages`, `.config`, `.params` accessors |
| Hook return value (Hash) | Merges `temperature:` override into LLM request |
| Hook execution order | Global → class → instance |

## Expected Output (approximate)

```
=== 16 Before-Completion Hook ===

--- Scenario 1: Global hook (usage accumulation) ---
[global hook] agent=LoggingAgent model=openai/gpt-oss-20b
Result: <LLM response>
[global hook] agent=LoggingAgent model=openai/gpt-oss-20b
Result: <LLM response>
Token usage accumulated: <N> calls logged

--- Scenario 2: Class-level hook (model param override) ---
[class hook] Setting temperature=0.0 for deterministic response
Result: <LLM response>

--- Scenario 3: Instance-level hook (per-instance override) ---
[instance hook] Overriding temperature to 1.0 for creative mode
Result: <LLM response>

Done.
```

## Implementation Steps

1. Create `16_before_completion_hook/hooks.rb`:
   - Define a global hook lambda that logs model + agent name
   - Define a class-level hook lambda that sets `temperature: 0.0`
   - Configure global hook via `Phronomy.configure`
2. Create `16_before_completion_hook/run.rb`:
   - Scenario 1: Run `LoggingAgent` twice; print usage summary
   - Scenario 2: Run `DeterministicAgent` (class hook sets temperature)
   - Scenario 3: Run an agent with instance hook setting `temperature: 1.0`
3. All files start with `# frozen_string_literal: true`
4. All LLM config from `shared/llm_config.rb`
