# 14 AI Code Review Pipeline

A larger example that composes Phronomy Workflow, stateful Agents,
Journal-backed Knowledge, streaming, Filters, application-level quality scoring,
and tracing into one application flow.

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
| Agent async lifecycle | `Agent#invoke_async`, `Agent#stream_async` | Reviewer and Improver work never blocks a Workflow EventLoop action |
| Persistent Knowledge | `knowledge:` | Reviewer criteria / improvement policy become Journal context candidates |
| Prompt template | `Agent::Context::Instruction::PromptTemplate` | Builds the improvement request |
| Synchronous-work boundary | `Runtime#offload` | The direct RubyLLM quality-judge call is isolated from EventLoop by the bounded OffloadPool |
| Tracing | `Phronomy::Tracing::Base` | Captures major pipeline stages |

`Phronomy::Testing::Eval` is intentionally **not** used by this production-style
application example. Eval is test support in current Phronomy. The two quality
scores here are implemented as an application service and the direct
synchronous RubyLLM request is submitted through `OffloadPool`.

The reviewer policies are ordinary application data registered as Agent
`knowledge:`. They participate in the Journal/candidate/context-policy pipeline
instead of using removed static-Knowledge APIs.

`OffloadPool` is used only to keep synchronous work off EventLoop. It is not a
Workflow scheduler and does not imply CPU isolation or distributed execution.

## Run

```bash
bundle exec ruby 14_code_review/run.rb path/to/your_file.rb
```

To bypass the interactive priority prompt:

```bash
bundle exec ruby 14_code_review/run.rb path/to/your_file.rb security
```

Batch review:

```bash
bundle exec ruby 14_code_review/batch_review.rb
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
   ├─ SecurityReviewerAgent.invoke_async
   ├─ PerformanceReviewerAgent.invoke_async
   ├─ ReadabilityReviewerAgent.invoke_async
   └─ AbstractionReviewerAgent.invoke_async
   ↓ completion callbacks → Workflow#signal
wait_state :awaiting_priority
   ↓ user event
ImproverAgent.stream_async
   ↓ completion callback → Workflow#signal
output Filter
   ↓
application quality judge
   ↓ Runtime#offload
Workflow completion
```

No application `Thread.new` is required. Logical asynchronous coordination is
represented by Phronomy completion handles and Workflow events; synchronous
third-party work that must not run on EventLoop is isolated by `OffloadPool`.
