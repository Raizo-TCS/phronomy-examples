# 23 Bounded Parallel Dispatch

## Purpose

Demonstrates bounded child-Agent fan-out through
`Phronomy::MultiAgent::Orchestrator`.

- **`max_concurrency: N`** — cap the number of child Agent invocations that are
  active at once. This is a logical concurrency bound, **not** an OS worker
  thread count.
- **`on_error: :skip`** — fill failed result slots with `nil` and continue
  (never raise for those child failures).
- **`on_error: :raise`** — propagate the first child error according to the
  Orchestrator contract (default).

Orchestrator delegates fan-out and fan-in control to Phronomy::Execution.
The existing max_concurrency limit bounds active child invocations. Child Agents retain their own Agent
FSMSessions; unavoidable provider I/O is isolated by Phronomy's blocking-I/O
boundary rather than by creating one application Thread per child.

The scenario is a product-review pipeline. Five reviews are processed in two
passes:

1. **Part 1 (`dispatch_parallel`)** — runs `SentimentAgent` on all five reviews with at
   most 3 active child invocations.
2. **Part 2 (`dispatch_parallel`)** — runs `SentimentAgent` and
   `KeywordExtractor` on two different reviews with at most 2 active child
   invocations.

## Phronomy Features

| Feature | Class / API | Role |
|---|---|---|
| Base agent | `Phronomy::Agent::Base` | Superclass for `SentimentAgent` and `KeywordExtractor` |
| Sentiment analysis agent | `SentimentAgent` | Classifies a review as POSITIVE, NEGATIVE, or NEUTRAL |
| Keyword extraction agent | `KeywordExtractor` | Extracts the three most important keywords from a review |
| Multi-agent orchestrator | `Phronomy::MultiAgent::Orchestrator` | Superclass for `ReviewOrchestrator`; provides `dispatch_parallel` |
| Homogeneous fan-out | `ReviewOrchestrator#analyze_sentiments` / `dispatch_parallel` | Runs the same Agent definition on multiple inputs with bounded active child invocations |
| Heterogeneous fan-out | `ReviewOrchestrator#mixed_analysis` / `dispatch_parallel` | Runs different Agent definitions on different inputs through the common Execution engine |
| Output validation helper | `OutputValidator.validate` | Asserts post-conditions on fan-out results in the example script |

## How to Run

```bash
cd phronomy-examples
bundle exec ruby 23_bounded_parallel/run.rb
```

An OpenAI-compatible LLM server (e.g., LM Studio) must be running, configured
via `shared/llm_config.rb`.

## Expected Output (approximate)

```text
=== 23 Bounded Parallel Dispatch ===

[1] Sentiment analysis — dispatch_parallel, max_concurrency: 3

  Review 1: POSITIVE — customer loved the fast shipping and quality.
  Review 2: NEGATIVE — product broke after just one day of use.
  Review 3: NEUTRAL — product performs as described with no standout qualities.
  Review 4: POSITIVE — customer highly recommends as best purchase this year.
  Review 5: NEGATIVE — customer disappointed by inaccurate product description.

[2] Mixed analysis — dispatch_parallel, max_concurrency: 2

  Sentiment [review 1]: POSITIVE — customer loved the fast shipping and quality.
  Keywords [review 2]: broke, experience, use

Done.
```

Actual wording varies by model. Any slot where the Agent fails is printed as
`(skipped — agent returned nil)` or `(skipped)` rather than raising when the
example selects `on_error: :skip`.

For application-defined result conversion and asynchronous evaluation, see
[32_async_composition](../32_async_composition/README.md).
