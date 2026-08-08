# 14 AI Code Review Pipeline

A comprehensive example covering many phronomy features in a single pipeline.

## Purpose

Accept a Ruby source file, run Security / Performance / Readability /
Abstraction Consistency reviews in parallel, let the user choose the priority
dimension, then generate and evaluate improved code.

## Phronomy Features

| Feature | Class / API | Usage |
|---------|-------------|-------|
| Input / output validation | `Phronomy::Filter::Base` | `FileInputGuardrail` rejects empty or non-Ruby; `CodeOutputGuardrail` validates code-block fence |
| Source chunking | `Phronomy::Splitter::RecursiveSplitter` | Splits large files into token-budget-aware chunks |
| Workflow | `Phronomy::Workflow.define` | Full pipeline as a state machine over `ReviewState` |
| State context | `Phronomy::WorkflowContext` | `ReviewState` fields: `file_path`, `source_code`, `chunks`, `reviews`, `priority`, `improved_code`, `eval_scores` |
| Interrupt / Resume | `wait_state` + `transition on:` | Pauses at `:awaiting_priority` for user input |
| Application-level parallelism | `Phronomy::Runtime.instance.pool` + `BlockingAdapterPool` | `BRANCH_POOL` runs four reviewer branches concurrently |
| Stateful improvement agent | `Persistence::InMemory` + `Agent.load/create` | `ImproverAgent` retains context per reviewed file via `IMPROVER_PERSISTENCE` |
| Reviewer agents | `Phronomy::Agent::Base` | `SecurityReviewerAgent`, `PerformanceReviewerAgent`, `ReadabilityReviewerAgent`, `AbstractionConsistencyReviewerAgent` |
| Static knowledge | `StaticKnowledge` | Review criteria cached in each reviewer |
| Prompt template | `Phronomy::Agent::Context::Instruction::PromptTemplate` | `IMPROVE_TEMPLATE` builds the improvement message |
| File-reading tool | `Phronomy::Agent::Context::Capability::Base` | `FileReadTool` reads Ruby source files |
| Eval | `Phronomy::Eval::Runner` + `LlmJudge` | Scores review and improvement quality 0-10 |
| Tracing | `Phronomy::Tracing::Base` | `ConsoleTracer` prints span name and elapsed time |

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
    -> FileInputGuardrail
    -> :load_and_split
         RecursiveSplitter
    -> :parallel_review
         BRANCH_POOL --> SecurityReviewerAgent    (blocking_io pool)
                     --> PerformanceReviewerAgent  (blocking_io pool)
                     --> ReadabilityReviewerAgent  (blocking_io pool)
                     --> AbstractionConsistencyReviewerAgent
    -> wait_state :awaiting_priority
         [User selects dimension]
         transition on: :proceed
    -> :improve
         IMPROVE_TEMPLATE (PromptTemplate)
         ImproverAgent (streaming, stateful via IMPROVER_PERSISTENCE)
         CodeOutputGuardrail
    -> :evaluate
         Eval::Runner + LocalLlmJudge
    -> __finish__
```

## File Structure

| File | Responsibility |
|------|----------------|
| `run.rb` | Entry point |
| `pipeline.rb` | `Phronomy::Workflow.define` assembly |
| `state.rb` | `ReviewState` (`Phronomy::WorkflowContext`) |
| `reviewers.rb` | Four reviewer agents |
| `improver.rb` | `ImproverAgent`; `IMPROVE_TEMPLATE`; `IMPROVER_PERSISTENCE` |
| `guardrails.rb` | `FileInputGuardrail` and `CodeOutputGuardrail` |
| `tools.rb` | `FileReadTool` |
| `tracer.rb` | `ConsoleTracer` |
| `sample.rb` | Sample Ruby file with intentional issues |
