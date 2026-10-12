# 01 Basic Workflow Pipeline

Demonstrates a simple single-node pipeline using `Phronomy::Workflow`.

## Purpose

Build a stateless, reusable code-generation pipeline with one node backed by
an `Agent::Base` subclass. The same workflow instance is invoked multiple times
with different inputs to show it has no side-effects between calls.

Each `task_state` starts an Agent TaskResult and applies its successful output
before normal transitions run. Phronomy owns completion correlation, stale-result
rejection and failure propagation; the Agent owns its model/tool execution.

## Phronomy Features

| Feature | Usage |
|---------|-------|
| `Phronomy::WorkflowContext` | Defines `language` and `output` fields via `field` |
| `Phronomy::Workflow.define` | Workflow definition API |
| `initial` / `state` / `transition` | Assembles the pipeline |
| `Phronomy::Agent::Base` | `CodeGeneratorAgent` drives the `:generate` node |
| `task_state` + `Agent#invoke_async` | Starts the operation and applies its successful result |
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
