# Spec: 19_trust_pipeline

## Purpose

Demonstrate `Phronomy::TrustPipeline` — a framework for producing trustworthy
LLM outputs by combining three complementary mechanisms:

1. **Citation Tracking** — the DraftAgent is prompted to cite its knowledge
   sources. Each answer includes `citations: [{source:, excerpt:}]`.

2. **Self-Review Loop** — a dedicated ReviewAgent scores the draft and provides
   actionable feedback. Rejected answers are retried with the feedback embedded
   in the next prompt.

3. **Confidence Gate** — the combined confidence (min of draft self-score and
   reviewer score) is compared against a threshold. The final `Result` exposes
   `trusted?` and `confidence` so callers can decide how to handle low-confidence
   answers.

## Phronomy Features Demonstrated

- `Phronomy::TrustPipeline`
- `Phronomy::KnowledgeSource::StaticKnowledge` with `source:` label
- `Phronomy::Context::Assembler` `source` attribute in XML context tags
- `Phronomy::Agent::Base` with `static_knowledge`

## Knowledge Base

Two fictional company policy documents:

- `knowledge/refund_policy.md` — refund window, conditions, process
- `knowledge/shipping_policy.md` — shipping tiers, timelines, regions

## Scenarios

| # | Question | Expected outcome |
|---|----------|-----------------|
| 1 | "What is the refund policy?" | High confidence; cited from refund_policy.md; trusted |
| 2 | "How long does express shipping take?" | High confidence; cited from shipping_policy.md; trusted |
| 3 | "Can I get a refund after 60 days?" | Lower confidence (policy says 30 days); may require review loop |

## Expected Output (approximate)

```
=== Scenario 1: Refund Policy ===
Output    : Customers may request a full refund within 30 days of purchase...
Trusted   : true
Confidence: 0.82
Iterations: 1
Citations :
  - refund_policy.md: "full refund within 30 days of purchase"

=== Scenario 2: Express Shipping ===
Output    : Express shipping arrives within 1-2 business days...
Trusted   : true
...
```

## Implementation Steps

1. Write spec document (this file)
2. Create `knowledge/refund_policy.md` and `knowledge/shipping_policy.md`
3. Create `agents.rb` with `PolicyDraftAgent` and `PolicyReviewAgent`
4. Create `run.rb` with 3 scenarios using `Phronomy::TrustPipeline`
5. Create `README.md`
6. Run and verify
