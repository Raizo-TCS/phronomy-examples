# 28_filter

## Purpose

Demonstrates `Phronomy::Filter::Base` — the unified filter interface for
transforming or blocking values at three agent boundaries: user input, LLM
output, and tool return values.

## Phronomy features demonstrated

- `Phronomy::Filter::Base` — abstract base class with `call(value, **context)`
- `Agent::Base#add_input_filter` — masks or blocks user input
- `Agent::Base#add_tool_result_filter(ToolClass, filter)` — per-tool result filter
- `Agent::Base#add_output_filter` — transforms the final LLM output
- `Phronomy::FilterBlockError` — raised by `block!` inside a filter
- Reusing the same filter instance at multiple boundaries

## Expected output (approximate)

```
=== 28 Filter Example ===

--- Scenario 1: input filter (PII masking in user input) ---
Input '4111-1111-1111-1111' was masked to [CARD] before reaching the LLM.

--- Scenario 2: tool result filter (PII masking in tool return value) ---
Raw tool output:      Customer C001: email=alice@example.com phone=090-1234-5678 card=4111-1111-1111-1111
Filtered tool output: Customer C001: email=[EMAIL] phone=[PHONE] card=[CARD]

--- Scenario 3: blocking filter (NoSecretFilter) ---
Blocked as expected: Value contains forbidden word 'secret'

--- Scenario 4: same PiiMaskFilter on input and output ---
PiiMaskFilter registered at both input and output boundaries.
Any PII in user input or in the LLM's final answer will be masked.

Done.
```

## Implementation steps

1. Define `PiiMaskFilter < Phronomy::Filter::Base` — masks phone, card, email patterns
2. Define `NoSecretFilter < Phronomy::Filter::Base` — calls `block!` on forbidden input
3. Register filters on agent instances via `add_input_filter`, `add_output_filter`,
   and `add_tool_result_filter`
4. Show the same filter class reused at multiple sites
