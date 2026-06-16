# 12 Prompt Template

Demonstrates `Phronomy::Agent::Context::Instruction::PromptTemplate` with named
`{{variable}}` placeholders.

## Purpose

Show how to decouple prompt authoring from runtime data by using a template
that is filled with values at invocation time. Also demonstrates wiring a
`PromptTemplate` directly into an agent's `instructions` DSL.

## Phronomy Features

| Feature | Usage |
|---------|-------|
| `Phronomy::Agent::Context::Instruction::PromptTemplate.new(template:, system_template:)` | Template with `{{variable}}` placeholders |
| `#variables` | Lists all placeholder names as `Array<Symbol>` |
| `#format(**variables)` | Expands placeholders in the human template; returns `String` |
| `#format_system(**variables)` | Expands placeholders in the system template; returns `String` or `nil` |
| `#invoke(hash)` | Expands both templates; returns `{ prompt:, system: }` |
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
System msg:   You are a professional French translator. Reply with only the translated text.

--- Agent with PromptTemplate instructions ---

Translation: Buenos días, ¿cómo estás?
```

Part 1 shows standalone template rendering via `#invoke`, printing both the
human prompt and the expanded system message. Part 2 shows the template wired
into `TranslatorAgent.instructions` with variables injected via `invoke`.
