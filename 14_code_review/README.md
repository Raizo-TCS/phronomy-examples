# 14 AI Code Review Pipeline

A comprehensive example covering many phronomy features in a single pipeline.

## Purpose

Accept a Ruby source file, run Security / Performance / Readability /
Abstraction Consistency reviews in parallel, let the user choose the priority
dimension, then generate and evaluate improved code.

## Phronomy Features

| Feature | Class / API | Usage |
|---------|-------------|-------|
| Input / output validation | `Phronomy::Filter::Base` | `FileInputGuardrail` rejects empty or non-Ruby input; `CodeOutputGuardrail` validates the code-block fence |
| Source chunking | `Phronomy::Splitter::RecursiveSplitter` | Splits large files into token-budget-aware chunks before review |
| Workflow | `Phronomy::Workflow.define` | Defines the full pipeline as a state machine over `ReviewState` |
| State context | `Phronomy::WorkflowContext` | `ReviewState` fields: `file_path`, `source_code`, `chunks`, `reviews`, `priority`, `improved_code`, `eval_scores` |
| Interrupt / Resume | `wait_state` + `transition on:` | Pauses at `:awaiting_priority` for user input; resumes on `:proceed` |
| Application-level parallelism | `Phronomy::Runtime.instance.pool` + `BlockingAdapterPool` | `BRANCH_POOL` runs four reviewer branches concurrently; `blocking_io` pool handles per-chunk LLM calls |
| Session memory | Plain `Hash` (`REVIEW_SESSIONS`) | Accumulates `ImproverAgent` message history across repeat runs, keyed by `thread_id` |
| Reviewer agents | `Phronomy::Agent::Base` | `SecurityReviewerAgent`, `PerformanceReviewerAgent`, `ReadabilityReviewerAgent`, `AbstractionConsistencyReviewerAgent` |
| Static knowledge | `Phronomy::Agent::Context::Knowledge::StaticKnowledge` | Review criteria cached via `ContextVersionCache` in each reviewer |
| Improvement agent | `Phronomy::Agent::Base` (streaming) | `ImproverAgent` generates improved code with real-time token output |
| Prompt template | `Phronomy::Agent::Context::Instruction::PromptTemplate` | `IMPROVE_TEMPLATE` builds the improvement user message from `priority`, `source_excerpt`, `char_count`, `review_text` variables |
| File-reading tool | `Phronomy::Agent::Context::Capability::Base` | `FileReadTool` reads a Ruby source file from disk |
| Eval | `Phronomy::Eval::Runner` + `Phronomy::Eval::Scorer::LlmJudge` | `LocalLlmJudge` scores review quality and improvement quality on a 0–10 scale |
| Tracing | `Phronomy::Tracing::Base` | `ConsoleTracer` prints span name and elapsed time for every pipeline stage |

## How to Run

```bash
bundle exec ruby 14_code_review/run.rb path/to/your_file.rb
```

Pass an optional second argument to skip the interactive priority prompt:

```bash
bundle exec ruby 14_code_review/run.rb path/to/your_file.rb security
```

## Pipeline Flow

```
[Input file path]
    ↓ FileInputGuardrail (Phronomy::Filter::Base) — reject empty / non-Ruby / missing files
    ↓ :load_and_split node
         RecursiveSplitter — token-budget-aware chunking
    ↓ :parallel_review node
         BRANCH_POOL (Runtime.instance.pool) ──→ SecurityReviewerAgent     (blocking_io pool)
                                              ──→ PerformanceReviewerAgent  (blocking_io pool)
                                              ──→ ReadabilityReviewerAgent  (blocking_io pool)
                                              ──→ AbstractionConsistencyReviewerAgent (blocking_io pool)
    ↓ wait_state :awaiting_priority
         [User selects: security / performance / readability / abstraction]
         transition on: :proceed
    ↓ :improve node
         IMPROVE_TEMPLATE (PromptTemplate) — builds user message
         ImproverAgent (streaming) — generates improved code
         REVIEW_SESSIONS (Hash) — conversation history keyed by thread_id
         CodeOutputGuardrail (Phronomy::Filter::Base) — validates ``` fence
    ↓ :evaluate node
         Eval::Runner + LocalLlmJudge — scores review quality and improvement quality
    ↓ __finish__
```

## File Structure

| File | Responsibility |
|------|---------------|
| `run.rb` | Entry point: configures tracer, runs the interactive loop |
| `pipeline.rb` | `Phronomy::Workflow.define` assembly; all nodes and parallel branches |
| `state.rb` | `ReviewState` (`Phronomy::WorkflowContext`) |
| `reviewers.rb` | Four reviewer agents; `StaticKnowledge` criteria constants |
| `improver.rb` | `ImproverAgent`; `IMPROVE_TEMPLATE` (`PromptTemplate`); `REVIEW_SESSIONS` |
| `guardrails.rb` | `FileInputGuardrail` and `CodeOutputGuardrail` (`Phronomy::Filter::Base`) |
| `tools.rb` | `FileReadTool` (`Phronomy::Agent::Context::Capability::Base`) |
| `tracer.rb` | `ConsoleTracer` (`Phronomy::Tracing::Base`) |
| `sample.rb` | Sample Ruby file to review |

## Expected Output (approximate)

```
[Splitter] 42 lines (~310 tokens) → 1 chunk(s) (chunk_size: 3200 chars, available: 800 tokens)
[SPAN] load_and_split          elapsed=12ms

[parallel_review] Running 4 branches concurrently...
[SPAN] security_review         elapsed=4823ms
[SPAN] performance_review      elapsed=3901ms
[SPAN] readability_review      elapsed=4102ms
[SPAN] abstraction_review      elapsed=4550ms

==================================================
Review Results
==================================================

Security:
  [HIGH] line 12 — SQL query built with string interpolation; use parameterised queries
  [LOW]  line 34 — rescue Exception catches too broadly

Performance:
  (no issues found)

Readability:
  [MEDIUM] line 5 — method `do_stuff` is poorly named; prefer a domain verb

Abstraction Consistency:
  [MEDIUM] line 18 — high-level `process_order` mixes raw SQL manipulation at the same level

Which area would you like to improve?
  1) security
  2) performance
  3) readability
  4) abstraction
  5) all (security)
> 1

[ImproverAgent] Generating improvements (streaming)...
```ruby
# (improved Ruby code)
```

[OutputGuardrail] Output validation passed.
[SPAN] improve                 elapsed=6241ms

==================================================
Eval Scores (LLMJudge, scale 0–10)
==================================================
  Review quality:      8.0 / 10
  Improvement quality: 7.5 / 10
==================================================
[SPAN] evaluate                elapsed=3102ms
```
