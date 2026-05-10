# 06 Guardrails

Demonstrates input and output guardrails on an `Agent::Base`.

## Purpose

Show how to attach validation logic before the LLM sees the user's input
and after the LLM produces its output, blocking unsafe or non-compliant
content at both boundaries.

## Phronomy Features

| Feature | Usage |
|---------|-------|
| `Phronomy::Guardrail::InputGuardrail` | Validates (and optionally blocks) user input |
| `Phronomy::Guardrail::OutputGuardrail` | Validates (and optionally blocks) LLM output |
| `Phronomy::GuardrailError` | Raised when a guardrail calls `fail!` |
| `add_input_guardrail` / `add_output_guardrail` | Attaches guardrails to an agent |

## Guardrails in This Example

| Guardrail | Trigger | Action |
|-----------|---------|--------|
| `NoPIIInputGuardrail` | Input contains a 12-digit number (My Number format) | Blocks with `GuardrailError` |
| `NoURLOutputGuardrail` | LLM output contains an `http(s)://` URL | Blocks with `GuardrailError` |

## How to Run

```bash
bundle exec ruby 06_guardrails/run.rb
```

## Expected Output (approximate)

```
=== Guardrails Example ===

[Test 1] Normal input:
Response: Ruby is a dynamic, expressive programming language...

[Test 2] PII input (12-digit number):
BLOCKED: PII detected in input

[Test 3] URL output suppression:
BLOCKED: URL detected in output
```
