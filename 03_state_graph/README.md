# 03 State Graph

Demonstrates conditional branching and looping inside a `StateGraph`.

## Purpose

Build a self-improving text pipeline. The graph evaluates text quality and,
if the score is below the threshold (and the iteration limit has not been
reached), rewrites the text and re-evaluates — up to three times.

## Phronomy Features

| Feature | Usage |
|---------|-------|
| `Phronomy::Graph::State` | `field` DSL with `:replace` / `:append` policies |
| `StateGraph` | Node / edge / conditional-edge definitions |
| `add_conditional_edges` | Router function controlling loop or exit |
| `compile` → `invoke` | Graph execution |

## State Fields

| Field | Type | Description |
|-------|------|-------------|
| `text` | String | Current version of the text |
| `score` | Integer | Quality score 0–10 |
| `iterations` | Integer | Number of improvement rounds |

## Flow

```
START → :evaluate → (score >= 7 or iterations >= 3) → :finish → FINISH
                 ↓ (otherwise)
              :improve → :evaluate
```

## How to Run

```bash
bundle exec ruby 03_state_graph/run.rb
```

## Expected Output (approximate)

```
=== State Graph Example ===
Initial text: "Ruby is ok."

[Iteration 1] Score: 4 → improving...
[Iteration 2] Score: 7 → done.

Final text: "Ruby is an elegant, expressive language ..."
```
