# 19 — Trust pipeline with persistent Knowledge + Generator/Verifier

This example combines two current Phronomy concepts:

1. **Journal-backed Agent Knowledge**
2. **Generator/Verifier multi-agent control**

`PolicyDraftAgent` receives the refund and shipping policies through its
`knowledge:` initialization. Those documents become persistent context
candidates for that logical Agent; they are not implemented through the removed
`StaticKnowledge` / `static_knowledge` API.

`PolicyReviewAgent` then acts as the verifier in the Generator/Verifier loop.

Conceptually:

```text
policy files
   ↓
PolicyDraftAgent persistent Knowledge
   ↓
draft
   ↓
PolicyReviewAgent
   ├─ accepted → final answer
   └─ rejected → feedback → regenerate
```

This example is useful when correctness is not just "call an LLM once": the
knowledge boundary and the quality-control loop are explicit.

Run:

```bash
bundle exec ruby 19_trust_pipeline/run.rb
```
