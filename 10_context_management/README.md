# 10 Context Management

Demonstrates phronomy's context window management utilities without making
real LLM API calls.

## Purpose

Explore the tools available for fitting conversation history and documents
into a model's context window: token estimation, budget enforcement, sliding
window retrieval, and recursive text splitting.

## Phronomy Features

| Feature | Usage |
|---------|-------|
| `Phronomy::Context::TokenEstimator` | Estimates token count for a string |
| `Phronomy::Context::BudgetEnforcer` | Trims messages to fit within a token budget |
| `Phronomy::Memory::Retrieval::Window` | Returns the most recent N messages |
| `Phronomy::Splitter::RecursiveSplitter` | Splits long text into overlapping chunks |

## How to Run

```bash
bundle exec ruby 10_context_management/run.rb
```

## Expected Output (approximate)

```
=== Context Management Example ===

--- 1. TokenEstimator ---
"Hello, world!" → ~4 tokens

--- 2. BudgetEnforcer ---
Budget: 100 tokens → kept 3 of 5 messages

--- 3. Window Retrieval ---
Last 3 messages: [...]

--- 4. RecursiveSplitter ---
Chunk 1/3: "Ruby is a dynamic..."
```
