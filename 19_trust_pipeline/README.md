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

## Content fidelity and reproducible live acceptance

The invoice demo compares its fixed fixture against an independent expected
identifier and total. A schema-valid transcription error exits 1. It does not
repair values, constrain the schema to the expected identifier, or retry until
the fixture passes. This belongs to application acceptance; Agent's schema
guarantee and GeneratorVerifier's accepted result do not certify business truth.

The default `bash scripts/verify_examples.sh` automatically runs all six cases
as the RSpec integration suite `integration/trust_pipeline_spec.rb`. A blocked
case is an unmet acceptance criterion: it fails the RSpec example and makes the
overall verification exit nonzero. Reports still distinguish `blocked` from
`failed`; a server capability rejection does not establish a framework defect.
`--syntax-only` explicitly skips all six live cases. `--preflight-only` does not
run acceptance tests.

Run the complete live suite independently with the intended model and server:

```bash
bundle exec rspec integration/trust_pipeline_spec.rb --format documentation
```

Each suite run creates a new `tmp/trust-live-*` directory containing per-case
JSON evidence, stdout/stderr logs and `summary.json`. The suite runs each CLI in
a separate process and inherits the caller's model, provider and credentials.
It does not load the offline `spec/spec_helper.rb`, change SDK timeouts/retries,
or retry failed acceptance cases. The usual offline CI still runs `spec/`:
its controlled HTTP regressions check this live-suite wiring without claiming
real-model acceptance.

For diagnosis, individual cases remain available with fresh report paths:

```bash
bundle exec ruby scripts/verify_trust_pipeline.rb --case invoice --report tmp/trust/invoice.json
bundle exec ruby scripts/verify_trust_pipeline.rb --case accepted --report tmp/trust/accepted.json
bundle exec ruby scripts/verify_trust_pipeline.rb --case iteration_limit --report tmp/trust/iteration-limit.json
bundle exec ruby scripts/verify_trust_pipeline.rb --case approval-yes --report tmp/trust/approval-yes.json
bundle exec ruby scripts/verify_trust_pipeline.rb --case approval-no --report tmp/trust/approval-no.json
bundle exec ruby scripts/verify_trust_pipeline.rb --case approval-cancel --report tmp/trust/approval-cancel.json
```

The runner supplies the explicit approval input to the existing CLI. The only
Tool is the bundled fictional policy lookup. A case cannot pass by skipping the
Tool call and returning a plausible answer. Yes requires one approval, one Tool
execution and valid completion (accepted or iteration_limit); the separate
accepted case checks adoption. No/cancel require zero Tool effects and release.

Exit codes: 0 passed, 1 failed, 2 blocked by native-schema capability rejection.
A blocked approval is not an OK. Retain failed trials when comparing settings;
this small fixed set does not establish general model accuracy. An existing
report path is rejected: use a fresh path for every trial.

Use the usual PHRONOMY_MODEL, PHRONOMY_PROVIDER, PHRONOMY_BASE_URL and credentials.
Declare only verified capabilities. Set PHRONOMY_SERVER_VERSION to the observed
server version; unknown remains null. Separate capability flags do not establish
schema-plus-Tool combination support; the approval cases test the actual request.

Reports include SDK timeout/retry settings, requests/responses, physical HTTP
attempts, Tool effects, approvals, results and release outcomes. Ruby thread
stacks are written every 30 seconds; --snapshot-interval changes observation
frequency only. The runner neither shortens SDK timeouts nor adds cancellation.
It uses diagnostic bindings to the pinned SDK. An observer failure invalidates
the report instead of masking the application exception.

For a long wait, preserve the running report and server logs before interrupting.
Correlate UTC times, endpoint path and payload hash/content. External signals,
including those wrapped in cleanup failures, are recorded as interrupted.
They do not count as successful cancellation/release. Sampling adds overhead.
Reports contain prompt/response data and should be retained as test evidence.

The original historical wait remains unexplained without its server logs.
A subsequent fast response cannot identify its cause. Only the full default
`verify_examples.sh` run includes these live acceptance cases; offline CI,
`--syntax-only` and `--preflight-only` do not establish live acceptance.
