# 14 AI Code Review Pipeline

A comprehensive example covering many phronomy features in a single pipeline.

## Purpose

Accept a Ruby source file, run Security / Performance / Readability reviews
in parallel, let the user choose the priority dimension, then generate and
evaluate improved code.

## Phronomy Features

| Feature | Usage |
|---------|-------|
| `Phronomy::Guardrail::InputGuardrail` | Rejects empty or non-Ruby input |
| `Phronomy::Splitter::RecursiveSplitter` | Chunks large files before review |
| `Phronomy::Graph::StateGraph` | Overall pipeline flow control |
| `Phronomy::Graph::ParallelNode` | Runs three review agents concurrently |
| Interrupt / Resume | Pauses for user to select review priority |
| `Phronomy::Memory::WindowMemory` | Persists review history across sessions |
| `Phronomy::Agent::Base` | Improvement code generation agent |
| `Phronomy::Tool::Base` | File-reading tool |
| `Phronomy::PromptTemplate` | Review and improvement prompt templates |
| `Phronomy::Tracing::Base` | ConsoleTracer instruments the whole pipeline |

## How to Run

```bash
bundle exec ruby 14_code_review/run.rb path/to/your_file.rb
```

## Pipeline Flow

```
[Input file]
    ↓ InputGuardrail (validation)
    ↓ RecursiveSplitter (chunking)
    ↓ ParallelNode → Security review
                  → Performance review
                  → Readability review
    ↓ [INTERRUPT] User selects priority dimension
    ↓ ImprovementAgent (generates improved code)
    ↓ OutputGuardrail (validates code block format)
    ↓ LLMJudge (scores the improvement)
```

## Expected Output (approximate)

```
=== AI Code Review Pipeline ===
Reviewing: your_file.rb

[Security]     Score: 7/10 — Found 2 issues: ...
[Performance]  Score: 8/10 — Suggestion: ...
[Readability]  Score: 6/10 — Naming could be improved.

Select review priority [security/performance/readability]: security

--- Improved Code ---
# (improved Ruby code)

Evaluation score: 8.5/10
```
