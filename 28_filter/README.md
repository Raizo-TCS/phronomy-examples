# 28 Filter

## Purpose

Demonstrates `Phronomy::Filter::Base` — the unified filter interface for
transforming or blocking values at three agent boundaries: user input, LLM
output, and tool return values.

Two filter classes are defined (`PiiMaskFilter`, `NoSecretFilter`) and applied
across five scenarios, showing both instance-level registration methods and the
class-level DSL macros.

No live LLM call is needed for scenarios 1, 2, 3, or 5; the filters are
exercised directly against known strings.

## Phronomy Features

| Class / Method | Role |
|---|---|
| `Phronomy::Filter::Base` | Abstract base class; subclasses implement `call(value, **context)` |
| `Phronomy::FilterBlockError` | Raised by `block!` inside a filter to abort processing |
| `Phronomy::Agent::Base#add_input_filter` | Registers a filter applied to user input before the LLM is called |
| `Phronomy::Agent::Base#add_output_filter` | Registers a filter applied to the final LLM output before it is returned |
| `Phronomy::Agent::Base#add_tool_result_filter` | Registers a per-tool filter applied to that tool's return value |
| `Phronomy::Agent::Base.input_filter` | Class-level DSL macro; applies to every instance |
| `Phronomy::Agent::Base.output_filter` | Class-level DSL macro; applies to every instance |
| `Phronomy::Agent::Base.tool_result_filter` | Class-level DSL macro; applies to every instance |
| `Phronomy::Agent::Context::Capability::Base` | Base class for tool definitions (`CustomerLookupTool`) |

## How to Run

```bash
cd /path/to/phronomy-examples
bundle exec ruby 28_filter/run.rb
```

No running LLM server is required; all scenarios exercise the filter layer
directly.

## Expected Output

```
=== 28 Filter Example ===

--- Scenario 1: input filter (PII masking in user input) ---
Original input: My card is 4111-1111-1111-1111 and phone is 090-1234-5678, please help.
After filter:   My card is [CARD] and phone is [PHONE], please help.

--- Scenario 2: tool result filter (PII masking in tool return value) ---
Raw tool output:      Customer C001: email=alice@example.com phone=090-1234-5678 card=4111-1111-1111-1111
Filtered tool output: Customer C001: email=[EMAIL] phone=[PHONE] card=[CARD]

--- Scenario 3: blocking filter (NoSecretFilter) ---
Blocked as expected: Value contains forbidden word 'secret'

--- Scenario 4: same PiiMaskFilter on input and output ---
PiiMaskFilter registered at both input and output boundaries.
Any PII in user input or in the LLM's final answer will be masked.

--- Scenario 5: class-level filter DSL ---
SecureCustomerAgent tool result: Customer C002: email=[EMAIL] phone=[PHONE] card=[CARD]
Class-level input_filter and output_filter will mask PII on every invoke.

Done.
```

### What each scenario covers

| Scenario | What it shows |
|---|---|
| 1 — Input filter | `PiiMaskFilter` replaces credit-card and phone patterns in raw user input |
| 2 — Tool result filter | `add_tool_result_filter` wraps `CustomerLookupTool` so the raw PII-bearing response is masked before it reaches the agent |
| 3 — Blocking filter | `NoSecretFilter` calls `block!`, raising `Phronomy::FilterBlockError` when the input contains the word "secret" |
| 4 — Reuse at multiple boundaries | The same `PiiMaskFilter` instance is registered at both `add_input_filter` and `add_output_filter` on the same agent |
| 5 — Class-level DSL | `input_filter`, `output_filter`, and `tool_result_filter` macros inside `SecureCustomerAgent` automatically apply `PiiMaskFilter` to every instance without instance-level setup |
