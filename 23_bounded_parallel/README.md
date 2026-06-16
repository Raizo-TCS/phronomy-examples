# 23 Bounded Parallel Dispatch

## Purpose

Demonstrates the concurrency control options added to `Phronomy::MultiAgent::Orchestrator` in v0.5.4:

- **`max_concurrency: N`** — cap the number of concurrent worker threads when running agents in parallel
- **`on_error: :skip`** — fill failed task slots with `nil` and continue (never raise)
- **`on_error: :raise`** — re-raise the first error (in input order) after all tasks complete (default)

The scenario is a product-review pipeline. Five reviews are processed in two passes:

1. **Part 1 (`fan_out`)** — runs `SentimentAgent` on all five reviews with a cap of 3 concurrent threads.
2. **Part 2 (`dispatch_parallel`)** — runs `SentimentAgent` and `KeywordExtractor` on two different reviews simultaneously with a cap of 2 concurrent threads.

## Phronomy Features

| Feature | Class / API | Role |
|---|---|---|
| Base agent | `Phronomy::Agent::Base` | Superclass for `SentimentAgent` and `KeywordExtractor` |
| Sentiment analysis agent | `SentimentAgent` | Classifies a review as POSITIVE, NEGATIVE, or NEUTRAL |
| Keyword extraction agent | `KeywordExtractor` | Extracts the three most important keywords from a review |
| Multi-agent orchestrator | `Phronomy::MultiAgent::Orchestrator` | Superclass for `ReviewOrchestrator`; provides `fan_out` and `dispatch_parallel` |
| Homogeneous parallel dispatch | `ReviewOrchestrator#analyze_sentiments` / `fan_out` | Runs the same agent on multiple inputs with `max_concurrency:` and `on_error:` |
| Heterogeneous parallel dispatch | `ReviewOrchestrator#mixed_analysis` / `dispatch_parallel` | Runs different agents on different inputs with `max_concurrency:` and `on_error:` |
| Output validation helper | `OutputValidator.validate` | Asserts post-conditions on parallel results in the example script |

## How to Run

```bash
cd /home/raizo-tcs/ruby_ai_agent_framework/phronomy-examples
bundle exec ruby 23_bounded_parallel/run.rb
```

An OpenAI-compatible LLM server (e.g., LM Studio) must be running, configured via `shared/llm_config.rb`.

## Expected Output (approximate)

```
=== 23 Bounded Parallel Dispatch ===

[1] Sentiment analysis — fan_out, max_concurrency: 3

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

Actual wording varies by model. Any slot where the agent fails is printed as `(skipped — agent returned nil)` or `(skipped)` rather than raising an error.
