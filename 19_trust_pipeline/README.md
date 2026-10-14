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
This branch pins the paired core Git revision in all seven bundles until that
update is published. PHRONOMY_PATH selects an explicit local checkout instead.

Each scenario uses GeneratorVerifier.open and returns the invocation Task.
The pipeline owns iteration of valid evaluations; no outer OutputValidator
replays failed output acquisition. accepted? means the configured review
conditions were met. Application publication remains a separate decision.
termination_reason distinguishes accepted, iteration_limit, tool_rejected and
output_failed. Result.to_h/from_h preserve those facts; citation keys are strings.

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

## Declared output and output failure

The paired structured-output update makes Agent responsible for strict JSON and
schema validation. GeneratorVerifier owns the draft/review schemas and decides
whether the validated evaluation satisfies the configured threshold. Application
prompts specify the business question, evidence and review criteria. They do not
repeat JSON templates or repair malformed model output.

For a local model outside RubyLLM's catalog, declare verified capabilities through
`PHRONOMY_MODEL_CAPABILITIES`, for example
`function_calling,streaming,structured_output`. The approval draft Agent explicitly
uses `LLMConfig::MODEL` and `LLMConfig::PROVIDER`; a subclass does not inherit a
model declaration. The approval demo requires native schema and Tool support in
the same request. The tested LM Studio configuration rejects that combination
with `Cannot combine structured output constraints with lazy grammar`; Phronomy
reports `LLMAdapter::StructuredOutputUnsupportedError` without executing the Tool
or removing the schema. Use a supporting model/server configuration to exercise
yes/no/cancel. Standalone schema examples can still run on a schema-only server.

`output_failed` identifies an unavailable evaluation, including malformed JSON,
model refusal and an incomplete answer. Its `failure` diagnostic and
`interrupted_phase` survive Hash/JSON round trips. It is different from
`iteration_limit`, which means valid evaluations did not meet the configured
conditions. The example does not automatically replay Agent/Tool work after an
output failure. `citation_schema:` can declare a different citation object shape.

`GeneratorVerifier.open` waits for a directly returned TaskResult, then attempts
to release both owned Agents. A CleanupError retains `pipeline`, `failures`,
`result` and `primary_error`; the caller can retry `pipeline.release!` once the
cause is resolved. `Agent.open_scope` uses the same rules, with `error.scope`.
Arrays of Tasks and Tasks not returned from the block are not automatically awaited.

Additional complete examples:

```bash
bundle exec ruby 19_trust_pipeline/structured_agent_demo.rb
bundle exec ruby 19_trust_pipeline/lifetime_demo.rb
```

The first declares an invoice schema through `output_schema:` and receives a
validated String-key Hash in `result[:output]`. `result[:raw_output]` retains the
received JSON text. The second returns an asynchronous pipeline invocation from
the synchronous lifetime block.
