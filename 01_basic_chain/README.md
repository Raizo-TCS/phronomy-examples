# 01 Basic Workflow Pipeline

Demonstrates a simple single-node pipeline using `Phronomy::Workflow`.

## Purpose

Build a stateless, reusable code-generation pipeline with one node backed by
an `Agent::Base` subclass. The same workflow instance is invoked multiple times
with different inputs to show it has no side-effects between calls.

## Phronomy Features

| Feature | Usage |
|---------|-------|
| `Phronomy::WorkflowContext` | Defines `language` and `output` fields via `field` |
| `Phronomy::Workflow.define` | Workflow definition API |
| `initial` / `state` / `transition` | Assembles the pipeline |
| `Phronomy::Agent::Base` | `CodeGeneratorAgent` drives the `:generate` node |
| `invoke` | Executes the workflow with an initial state hash |

## How to Run

```bash
bundle exec ruby 01_basic_chain/run.rb
```

## Expected Output (approximate)

```
=== Basic Workflow Pipeline Example ===
Language: Ruby
--- Response ---
puts "Hello, World!"
```

The workflow is invoked for Ruby, Python, and JavaScript in sequence.
