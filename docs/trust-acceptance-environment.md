# Trust acceptance environment setup

The six live cases verify the configured model and server together with Phronomy
and the example application's explicitly selected transport mode. The default
`native` mode sends native response schemas and Tools together for approval
yes/no/cancel. `tool_then_schema` uses the existing approval demo's application
adapter to send them on separate turns of the same draft Agent. Declaring
`structured_output` and `function_calling` in the model registry does not add
combined support to a server.

An earlier LM Studio configuration rejected the combination before approval;
the later gpt-oss-20b diagnosis returned HTTP 200 with no native Tool call in the
combined requests. Neither satisfies approval acceptance. Keep these historical
results. Do not remove final output validation, replace the real model with a
stub, or convert blocked/failed cases to a pass when assessing live acceptance.

## Evaluate the example 19 adaptation with the current LM Studio environment

Keep the current server/model settings and connection variables. Record the
loaded model and context through the same metadata API used in the diagnosis,
before and after evaluation (expected current model gpt-oss-20b, context 131072).
Record runtime/server details as unknown if not verified. Server/model logs are
useful when available but are not a prerequisite for this evaluation. Do not
change SDK timeout/retry settings or the server configuration for this trial.

First run the actual existing approval case once:

```bash
export PHRONOMY_TRUST_LLM_MODE=tool_then_schema
mkdir -p tmp
trial_reports=$(mktemp -d "$PWD/tmp/trust19-adaptation.XXXXXX")
bundle exec ruby scripts/verify_trust_pipeline.rb \
  --case approval-yes --report "$trial_reports/approval-yes.json"
```

Require `status=passed`, one approval/positive decision, one actual Tool execution,
a validated GeneratorVerifier result (`accepted` or `iteration_limit`), successful
release, and `observation_complete=true`. The report must identify
`llm_compatibility_mode=tool_then_schema`, the application adapter, and
`combined_tool_schema_requests=0`. Its first HTTP request has Tools without
`response_format`; the next has the original draft schema and correlated Tool
result, without Tools; review has the original review schema without Tools.
HTTP 200 alone is not a pass.

If this first case succeeds, run the existing six-case suite in the same
environment and then the full existing verification. Each run has a new report
directory; retain failures as well as successes. Stop and diagnose failed,
blocked, interrupted or incomplete runs rather than repeating until they pass.

```bash
PHRONOMY_TRUST_REPORT_DIR="$trial_reports/six-cases" \
  bundle exec rspec integration/trust_pipeline_spec.rb --format documentation
# After all six pass, keep PHRONOMY_TRUST_LLM_MODE=tool_then_schema:
bash scripts/verify_examples.sh
```

The six cases and their pass/fail rules are unchanged. The full verification
inherits this mode for the approval acceptance subprocesses. Normal `run.rb`
already has schema-only draft/review Agents, so it needs no transport adjustment.
Passing this mode certifies the observed application-adapted path, not native
Tool+Schema support. `native` remains available for an explicit comparison in a
fresh process; it is never an automatic fallback.

The new policy uses Phronomy's existing LLMAdapter extension API and keeps the
GeneratorVerifier composition. It is limited to one policy lookup per draft,
OpenAI-compatible Chat Completions and non-streaming invocation. It does not
promise arbitrary multi-Tool loops or cross-process recovery. Detailed transport
and contract boundaries are in [example 19](../19_trust_pipeline/README.md).

## Provider configuration

`shared/llm_config.rb` maps `PHRONOMY_API_KEY` and `PHRONOMY_BASE_URL` to the
selected provider's public RubyLLM configuration settings. For example, Azure
uses `azure_api_key` and `azure_api_base`, while OpenAI uses `openai_api_key`
and `openai_api_base`. The generic key takes precedence over the selected
provider's environment key (`AZURE_API_KEY`, `OPENAI_API_KEY`, and so on).
It never falls back to another provider's key.

Select `PHRONOMY_PROVIDER` explicitly when switching services. If omitted, a
custom URL retains the existing OpenAI-compatible behavior; without a custom
URL, the model registry determines the provider. Shared configuration only maps
the common API key and base URL. Providers requiring region, project, IAM or
other authentication settings still require their SDK-specific configuration.
Unsupported generic settings raise an error instead of configuring OpenAI.

The OpenAI-compatible custom URL path keeps Chat Completions and system-role
configuration. Other providers retain the SDK's protocol selection. The helper
does not change request timeouts, retries, output schemas or Tool approval.
Custom endpoint context metadata stays unknown unless an explicit verified
limit is supplied; only the OpenAI-compatible path probes LM Studio metadata.

## Alternatively evaluate native mode with a compatible environment

1. Select `PHRONOMY_TRUST_LLM_MODE=native`. Record the actual server/runtime version and model deployment. Verify that
   their combination supports native schemas and Tools together. This document
   does not assert that a particular LM Studio update fixes the observed refusal.
2. Set model, provider, endpoint and credentials for that environment. Clear
   settings inherited from the previous local model, especially its context
   window and capabilities; supply only verified replacement metadata.
3. Run the live suite once and retain all six reports. A failed or blocked run
   remains evidence. Repeated execution until one run passes is not acceptance.
4. After all six cases pass, run the full `scripts/verify_examples.sh` with the
   same configuration. Report ordinary CI separately from real-model acceptance.

For an Azure deployment using its OpenAI v1 endpoint, replace the placeholders
below with the deployed resource and model names. Supply `AZURE_API_KEY` securely
in the execution environment; do not put credentials in repository files or
reports. If using `PHRONOMY_API_KEY` instead, it must be the Azure key.

```bash
unset PHRONOMY_API_KEY PHRONOMY_CONTEXT_WINDOW PHRONOMY_MODEL_CAPABILITIES PHRONOMY_SERVER_VERSION
export PHRONOMY_PROVIDER=azure
export PHRONOMY_TRUST_LLM_MODE=native
export PHRONOMY_MODEL='<deployment-name>'
export PHRONOMY_BASE_URL='https://<resource>.openai.azure.com/openai/v1'
# For a custom deployment name, declare capabilities only after checking them:
export PHRONOMY_MODEL_CAPABILITIES='function_calling,streaming,structured_output'
# Set PHRONOMY_CONTEXT_WINDOW only if the actual input limit is known.
# Set PHRONOMY_SERVER_VERSION to the verified service/API/deployment description.
bundle exec rspec integration/trust_pipeline_spec.rb --format documentation
```

The Azure path is covered by controlled local HTTP regression through the real
RubyLLM provider, including all six cases and the provider's authentication
header. This is not evidence that a particular cloud deployment passed live
acceptance. The real credentials and deployed model remain environment inputs.

## Remaining wait investigation

The previous long review wait and the separate CLI 19 cutoff remain unexplained.
The normal CLI guard is still 240 seconds (with the existing per-example
overrides). It can fire before the SDK's observed 300-second request timeout,
which also has three configured retries. An outer cutoff does not demonstrate
an SDK timeout, a framework deadlock, or successful cleanup.

`verify_examples.sh` now preserves a fresh `tmp/cli-<example>.*` directory for
every CLI run: `stdout.log`, `stderr.log`, `syntax.log`, and `execution.json`.
For CLI 19, `observation.json` additionally records requests, response bodies,
actual HTTP attempts, SDK settings, exceptions, pipeline identities and releases,
and Ruby thread stacks every five seconds. Files are private to their owner.
The guard sends TERM at the existing limit, then KILL after ten further seconds
if termination has not completed. It signals only its own command process group.

Read the parent `execution.json` first. Exit 124 means the outer cutoff was
reached; 137 means the process was killed, but alone does not identify who sent
KILL. Both fail verification. The last observation can still say `running` after
a forced kill. An earlier scenario's successful release does not establish
cleanup of the pending scenario. `all_observed_pipelines_released` matches
pipeline identities; false/null or a missing final value is unconfirmed cleanup,
not proof of a resource leak. A final snapshot is possible only when the child
gets to finish its diagnostic handler; periodic snapshots survive forced kills.

To observe SDK timeout/exception/cleanup behavior separately, run the same CLI
without the normal 240-second verification guard. This command deliberately
does not override SDK timeouts, retries, prompts or schemas:

```bash
mkdir -p tmp
diagnostic_dir=$(mktemp -d "$PWD/tmp/trust-cli-diagnostic.XXXXXX")
diagnostic_status=0
(umask 077
 bundle exec ruby scripts/observe_trust_cli.rb \
   --report "$diagnostic_dir/observation.json" --snapshot-interval 5 \
   > "$diagnostic_dir/stdout.log" 2> "$diagnostic_dir/stderr.log") || diagnostic_status=$?
printf '%s\n' "$diagnostic_status" > "$diagnostic_dir/exit-code.txt"
```

This diagnostic has no outer deadline. Run it under supervision. If an outer
guard is needed, record its value and exit status separately; reaching that
guard is another interrupted observation, not a completed SDK timeout test.
The wrapper rejects an existing report path. Its `completed` status means the
original CLI exited successfully; it does not mean all answers were accepted or
correct. Inspect each `results` entry. The separate six-case live suite remains
the acceptance authority, and a longer diagnostic does not replace a failed
240-second verification result.

Correlate UTC timestamps, request payload/hash and pending thread stack with the
matching LM Studio/server log. Report what the evidence establishes and what
remains unknown. Do not attribute a wait to the server solely because an HTTP
request started. Successful later calls or a different provider do not establish
the cause of the historical wait. Keep failed and blocked trials alongside the
new run's evidence while investigating the unresolved issue; do not overwrite
them with a successful later run.

## Approval acceptance handoff

Run `integration/trust_pipeline_spec.rb` with the selected mode in the actual
environment described above, then the full verification with exactly the same configuration.
The normal offline unit/integration CI and controlled HTTP fixture tests do not
establish that a deployed model/server supports the combination. Do not mark
live approval cases complete based only on those tests.

For each approval case, inspect its JSON and log: yes must reach approval, record
one positive decision and one Tool execution; no must record one negative decision,
zero Tool executions and `tool_rejected`; cancel must reach approval, record no
decision, execute no Tool and retain cancellation. All require successful release.
The existing runner checks these conditions. Rejection before approval remains
`blocked` and fails the suite. Also retain failed `accepted`/`iteration_limit`
trials: a schema violation detected by Agent is correct rejection, while the
expected live outcome remains unmet. Do not weaken schemas or replay until a
favorable result appears.

## Responsibility boundary

Provider selection, credentials and the explicit example 19 transport policy
belong to application composition. Core/SDK source is unchanged. Agent still
owns approval/execution and strict final-schema validation; Generation still
owns draft/review evaluation and its Result. The application adapter changes
native request fields at the existing transport extension point only. Default
native behavior and the schema definitions are unchanged; there is no fallback
generation, schema weakening or automatic acceptance replay.
