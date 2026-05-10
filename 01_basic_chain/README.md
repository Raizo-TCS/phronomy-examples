# 01 Basic Graph Pipeline

Demonstrates a simple two-node pipeline using `StateGraph`.

## Purpose

Build a stateless, reusable code-generation pipeline with two nodes connected
by a linear edge. The same graph instance is invoked multiple times with
different inputs to show it has no side-effects between calls.

## Phronomy Features

| Feature | Usage |
|---------|-------|
| `Phronomy::Graph::State` | Defines `language` and `output` fields |
| `Phronomy::Graph::StateGraph` | Graph definition API |
| `add_node` / `add_edge` / `set_entry_point` | Assembles the pipeline |
| `compile` / `invoke` | Executes the graph |

## How to Run

```bash
bundle exec ruby 01_basic_chain/run.rb
```

## Expected Output (approximate)

```
=== Basic Graph Pipeline Example ===
Language: Ruby
--- Response ---
puts "Hello, World!"
```

The pipeline is invoked for Ruby, Python, and JavaScript in sequence.
