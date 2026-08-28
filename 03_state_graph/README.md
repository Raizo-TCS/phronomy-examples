# 03 Workflow with Conditional Routing

Demonstrates conditional branching and looping using `Phronomy::Workflow` with
guard-based transitions.

## Purpose

Build a self-improving text pipeline. The workflow evaluates text quality and,
if the score is below the threshold (and the iteration cap has not been
reached), rewrites the text and re-evaluates — up to three times.

Agent execution remains independent from Workflow state. Each entry starts an
Agent with `invoke_async`, transforms its successful Task value with `Task#map`,
and converts terminal Task completion into an explicit `Workflow#signal` event.
Lifecycle events are not used because this example needs only terminal
completion.

## Phronomy Features

| Feature | Usage |
|---------|-------|
| `Phronomy::WorkflowContext` | `field` DSL with `:replace` policies |
| `Phronomy::Workflow.define` | State and transition definitions |
| `transition` with `guard:` | Lambda-based conditional routing |
| `Phronomy::Agent::Base` | `EvaluatorAgent` and `ImproverAgent` subclasses |
| `Agent#invoke_async` | Starts Agent execution without blocking the Workflow entry |
| `Task#map` / `Task#on_complete` | Transforms and observes terminal completion |
| `Workflow#signal` | Re-enters the Workflow through an explicit event |

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
=== Workflow Conditional Routing Example ===
Initial text: "Ruby is ok."

[Iteration 0] Score: 4
[Iteration 1] Score: 7
[Done] Final score: 7

Final text: "Ruby is an elegant, expressive language ..."
```
