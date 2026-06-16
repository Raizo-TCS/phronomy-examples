# 19 — Generator-Verifier (Trust Pipeline)

Demonstrates `Phronomy::GeneratorVerifier`: a framework for producing trustworthy LLM
outputs by combining three complementary mechanisms.

> **Note:** This example directory is named `19_trust_pipeline` for historical reasons.
> `Phronomy::TrustPipeline` was removed in v0.4.0 and replaced by
> `Phronomy::GeneratorVerifier`, which requires callers to supply their own prompt
> builders. The lambdas in `run.rb` serve as the reference implementation.

## Mechanisms

### 1. Citation Tracking

`PolicyDraftAgent` is given policy documents as
`Phronomy::Agent::Context::Knowledge::StaticKnowledge` with a `source:` label.
The `draft_prompt_builder` instructs the agent to cite which document and exact quote
it relied on. Each result carries a `citations` array: `[{source:, excerpt:}]`.

### 2. Self-Review Loop

A dedicated `PolicyReviewAgent` evaluates every draft via `review_prompt_builder`
and returns:

```json
{"approved": true, "score": 0.85, "feedback": ""}
```

Rejected drafts are retried with the reviewer's feedback injected into the next
`draft_prompt_builder` call. The loop runs up to `max_iterations` times.

### 3. Confidence Gate

The combined confidence score is `min(draft_self_confidence, review_score)`.  
When this score meets `confidence_threshold`, the result is marked `trusted: true`.
After `max_iterations` the pipeline finishes regardless and exposes the raw score.

## Files

| File | Purpose |
|------|---------|
| `run.rb` | Entry point; defines prompt builders and runs three scenarios |
| `agents.rb` | `PolicyDraftAgent` and `PolicyReviewAgent` class definitions |
| `knowledge/refund_policy.md` | 30-day refund window, conditions, process |
| `knowledge/shipping_policy.md` | Shipping tiers, delivery times, regions |

## Usage

```bash
bundle exec ruby 19_trust_pipeline/run.rb
```

## Expected Output

```
Question 1: What is the refund policy? ...
=== Scenario 1 ===
Output    : Customers may request a full refund within 30 days...
Trusted   : true
Confidence: 0.82
Iterations: 1
Citations :
  - refund_policy.md: "full refund within 30 days of purchase"
...
```

## Key APIs

```ruby
# Prompt builders must be provided by the caller.
# draft_prompt_builder: lambda { |input, feedback| ... }  -> String
# review_prompt_builder: lambda { |input, draft, citations| ... } -> String

pipeline = Phronomy::GeneratorVerifier.new(
  draft_agent:           PolicyDraftAgent,   # Phronomy::Agent::Base subclass
  review_agent:          PolicyReviewAgent,  # Phronomy::Agent::Base subclass
  draft_prompt_builder:  DRAFT_PROMPT_BUILDER,
  review_prompt_builder: REVIEW_PROMPT_BUILDER,
  confidence_threshold:  0.7,               # 0.0–1.0
  max_iterations:        3
)

result = pipeline.invoke("What is the refund policy?")
result.output      # => String
result.trusted?    # => true / false
result.confidence  # => Float 0.0–1.0
result.citations   # => [{source: String, excerpt: String}, ...]
result.iterations  # => Integer
```

## Attaching Knowledge Sources to Agents

```ruby
class PolicyDraftAgent < Phronomy::Agent::Base
  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  instructions "..."

  static_knowledge(
    Phronomy::Agent::Context::Knowledge::StaticKnowledge.new(
      File.read("knowledge/refund_policy.md"),
      type: :policy,
      source: "refund_policy.md"
    ),
    Phronomy::Agent::Context::Knowledge::StaticKnowledge.new(
      File.read("knowledge/shipping_policy.md"),
      type: :policy,
      source: "shipping_policy.md"
    )
  )
end
```
