# 14 AI Code Review Pipeline

A larger example that composes Phronomy Workflow, stateful Agents, Journal-backed
Knowledge, streaming, Filters, evaluation, and tracing into one application flow.

## Current Phronomy features

| Feature | API | Usage |
|---|---|---|
| Input/output boundary | `Phronomy::Filter::Base` | Validates source input and improved-code output |
| Source splitting | `Phronomy::VectorStore::Splitter::RecursiveSplitter` | Splits large Ruby files for reviewer calls |
| Workflow | `Phronomy::Workflow.define` | Models the full review lifecycle |
| Typed state | `Phronomy::WorkflowContext` | Carries source, chunks, findings, selection and result |
| Workflow HITL | `wait_state` + `transition on:` | Pauses until the user chooses a review priority |
| Event-driven completion | `Workflow#signal` | Async work returns to the FSM as later events |
| Agent | `Phronomy::Agent::Base` | Four reviewers plus a stateful improver |
| Persistent Knowledge | `knowledge:` | Reviewer criteria / improvement policy become Journal context candidates |
| Prompt template | `Agent::Context::Instruction::PromptTemplate` | Builds the improvement request |
| Streaming | `Agent#stream` | Streams the improved source |
| Eval | `Phronomy::Eval::Runner` | Scores review/improvement output |
| Tracing | `Phronomy::Tracing::Base` | Captures major pipeline stages |

The important context distinction is that the review policies are not injected
through the removed `StaticKnowledge` API. They are ordinary application data
registered as Agent `knowledge:` and therefore participate in the same
Journal/candidate/context-policy pipeline as other persistent Agent context.

## Run

```bash
bundle exec ruby 14_code_review/run.rb path/to/your_file.rb
```

To bypass the interactive priority prompt:

```bash
bundle exec ruby 14_code_review/run.rb path/to/your_file.rb security
```

## Flow

```text
source file
   ↓
Filter
   ↓
VectorStore::Splitter::RecursiveSplitter
   ↓
Workflow :parallel_review
   ├─ SecurityReviewerAgent       + Journal-backed Knowledge
   ├─ PerformanceReviewerAgent    + Journal-backed Knowledge
   ├─ ReadabilityReviewerAgent    + Journal-backed Knowledge
   └─ AbstractionReviewerAgent    + Journal-backed Knowledge
   ↓
wait_state :awaiting_priority
   ↓ user event
ImproverAgent (persistent Agent + knowledge: + streaming)
   ↓
output Filter
   ↓
Eval + tracing
```

The reviewer branches are application-level concurrent work. The Workflow
itself remains an event-driven state machine: long-running work completes by
calling `Workflow#signal`, rather than blocking an EventLoop action.
