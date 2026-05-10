# 19 — Trust Pipeline

Demonstrates `Phronomy::TrustPipeline`: a framework for producing trustworthy LLM
outputs by combining three complementary mechanisms.

## Mechanisms

### 1. Citation Tracking

The DraftAgent is given policy documents as `StaticKnowledge` with a `source:` label.
The pipeline prompts the agent to cite which document and exact quote it relied on.
Each `Result` carries a `citations` array: `[{source:, excerpt:}]`.

### 2. Self-Review Loop

A dedicated `ReviewAgent` evaluates every draft and returns:

```json
{"approved": true, "score": 0.85, "feedback": ""}
```

Rejected drafts are retried with the reviewer's feedback injected into the next
DraftAgent prompt. The loop runs up to `max_iterations` times.

### 3. Confidence Gate

The combined confidence score is `min(draft_self_confidence, review_score)`.  
When this score meets `confidence_threshold`, the result is marked `trusted: true`.
After `max_iterations` the pipeline finishes regardless and exposes the raw score.

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
pipeline = Phronomy::TrustPipeline.new(
  draft_agent:          PolicyDraftAgent,   # Phronomy::Agent::Base subclass
  review_agent:         PolicyReviewAgent,  # Phronomy::Agent::Base subclass
  confidence_threshold: 0.7,               # 0.0–1.0
  max_iterations:       3
)

result = pipeline.invoke("What is the refund policy?")
result.output       # => String
result.trusted?     # => true / false
result.confidence   # => Float 0.0–1.0
result.citations    # => [{source:, excerpt:}, ...]
result.iterations   # => Integer
result.review_notes # => Array<String>
```

## Knowledge Sources

- `knowledge/refund_policy.md` — 30-day refund window, conditions, process
- `knowledge/shipping_policy.md` — shipping tiers, delivery times, regions
