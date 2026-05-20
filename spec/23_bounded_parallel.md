# spec/23_bounded_parallel.md

## Purpose

Demonstrate the concurrency control keyword arguments added to
`Phronomy::Agent::Orchestrator#dispatch_parallel` and `#fan_out` in v0.5.4:

- `max_concurrency:` — caps the number of concurrent worker threads
- `on_error: :skip` — fills failed task slots with `nil` instead of raising
- `on_error: :raise` — re-raises the first error in input order after all tasks
  complete (the default; shown by contrast)

The scenario is a product-review analysis pipeline that processes five short
reviews using a bounded thread pool.

## Phronomy Features Demonstrated

- `Phronomy::Agent::Orchestrator` — `fan_out` and `dispatch_parallel`
- `max_concurrency:` keyword — limits concurrent threads to 3 (fan_out) and 2
  (dispatch_parallel) regardless of input list length
- `on_error: :skip` — a failed task slot returns `nil`; the batch continues
- `on_error: :raise` (default) — used for the heterogeneous dispatch to show the
  contrasting semantics via the README note

## Expected Output (approximate)

```
=== 23 Bounded Parallel Dispatch ===

[1] Sentiment analysis — fan_out, max_concurrency: 3

  Review 1: POSITIVE — customer praised quality and shipping speed.
  Review 2: NEGATIVE — product broke after one day.
  Review 3: NEUTRAL — met expectations without distinction.
  Review 4: POSITIVE — described as best purchase of the year.
  Review 5: NEGATIVE — product did not match its description.

[2] Mixed analysis — dispatch_parallel, max_concurrency: 2

  Sentiment [review 1]: POSITIVE — ...
  Keywords [review 2]: terrible, broken, experience

Done.
```

## Implementation Steps

1. Define `SentimentAgent` — classifies review as POSITIVE / NEGATIVE / NEUTRAL
   with a brief reason.
2. Define `KeywordExtractor` — extracts 3 comma-separated keywords.
3. Define `ReviewOrchestrator < Phronomy::Agent::Orchestrator` with two public
   methods:
   - `analyze_sentiments(reviews)` — calls `fan_out` with `max_concurrency: 3,
     on_error: :skip`.
   - `mixed_analysis(reviews)` — calls `dispatch_parallel` with heterogeneous
     agents, `max_concurrency: 2, on_error: :skip`.
4. In `run.rb`, invoke both methods and print results, skipping `nil` slots.
