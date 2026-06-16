# 06 Filters (formerly Guardrails)

Demonstrates input and output filters on an `Agent::Base`.

## Purpose

Show how to attach blocking or transforming logic before the LLM sees the user's
input and after the LLM produces its output, rejecting unsafe or non-compliant
content at both boundaries.

## Phronomy Features

| Feature | Usage |
|---------|-------|
| `Phronomy::Filter::Base` | Subclass to transform or block values |
| `Phronomy::FilterBlockError` | Raised when a filter calls `block!` |
| `add_input_filter` / `add_output_filter` | Attaches filters to an agent |

## Filters in This Example

| Filter | Trigger | Action |
|--------|---------|--------|
| `PIIFilter` | Input contains credit card / phone / email | Blocks with `FilterBlockError` |
| `PromptInjectionFilter` | Input contains injection patterns | Blocks with `FilterBlockError` |
| `NoURLOutputFilter` | LLM output contains an `http(s)://` URL | Blocks with `FilterBlockError` |

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
