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

## GeneratorVerifier lifetime and result API

This example requires the GeneratorVerifier lifecycle/result update after 0.29.0.
Use the paired core checkout via PHRONOMY_PATH until that update is published.

Each scenario uses GeneratorVerifier.open. OutputValidator retries stay inside
the block, so the same two Agent conversations are reused and then released.
accepted? means that the configured review conditions were met; application
publication remains a separate decision. termination_reason distinguishes accepted,
iteration_limit and tool_rejected. A Tool rejection does not trigger a validation
retry. Result.to_h and Result.from_h preserve evaluation facts through JSON;
citation keys in the final Result are strings.

For an application approval UI, configure on_approval, enqueue the notification,
and call Approval#respond_async(approved: true/false) after the user's decision.
invoke_async remains pending through approval. Never block inside the notification
callback. cancel_async requests cancellation; release! checks actual release safety.

Run `bundle exec ruby 19_trust_pipeline/approval_demo.rb` from the examples root
to see application-controlled Tool authorization. The notification callback only
enqueues a request. The CLI asks for yes/no/cancel outside the callback and routes
the explicit decision through the Approval handle. "no" returns tool_rejected;
"cancel" cancels the invocation. The protected Tool reads only the bundled
fictional policy document.
