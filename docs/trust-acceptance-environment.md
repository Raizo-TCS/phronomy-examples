# Trust acceptance environment setup

The six live cases verify the configured model and server together with Phronomy.
Approval yes/no/cancel require a server that accepts native response schemas and
Tools in the same request. Declaring `structured_output` and `function_calling`
in the model registry does not add this capability to a server.

The observed LM Studio configuration rejected the combination before producing
an approval notification. Keeping that rejection as `blocked` is intentional.
Do not remove the schema, replace the model with a stub, or convert blocked
cases to a pass when assessing live acceptance.

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

## Re-run with an available compatible environment

1. Record the actual server/runtime version and model deployment. Verify that
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

Run `integration/trust_pipeline_spec.rb` in the actual compatible environment
described above, then the full verification with exactly the same configuration.
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

Provider selection and credentials belong to example application composition.
Provider configuration and diagnostic observation change no core Contract, Agent,
Generation, Engine or Execution behavior. They introduce no fallback generation,
schema weakening or automatic acceptance replay. Contract diagram relationships
are unchanged.
