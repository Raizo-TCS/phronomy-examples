# 12 Prompt Template

Demonstrates `Phronomy::PromptTemplate` with named `{{variable}}` placeholders.

## Purpose

Show how to decouple prompt authoring from runtime data by using a template
that is filled with values at invocation time. Also demonstrates integrating
a `PromptTemplate` directly into an agent's `instructions` DSL.

## Phronomy Features

| Feature | Usage |
|---------|-------|
| `Phronomy::PromptTemplate.new(template:, system_template:)` | Template with `{{variable}}` placeholders |
| `#variables` | Lists all placeholder names |
| `#invoke(hash)` | Expands placeholders and returns `{ prompt:, system: }` |
| `Agent::Base.instructions(prompt_template)` | Passes a template as system instructions |

## How to Run

```bash
bundle exec ruby 12_prompt_template/run.rb
```

## Expected Output (approximate)

```
=== PromptTemplate Example ===

Variables:    [:language, :text]

Human prompt: Translate the following text to French: Hello, World!

--- TranslatorAgent ---
Bonjour, le monde!
```

Part 1 shows standalone template rendering; Part 2 shows the template wired
into an agent's `instructions` with variables injected via `invoke`.
