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

The previous long review wait remains unexplained. Capture the matching LM
Studio/server logs and the runner's time-stamped request and thread snapshots
if it recurs. The runner already writes diagnostic snapshots while waiting.
Successful later calls, a different provider, or this configuration fix do not
establish the cause of the historical wait.

## Responsibility boundary

Provider selection and credentials belong to example application composition.
This correction changes no core Contract, Agent, Generation, Engine or Execution
behavior. It introduces no fallback generation, schema weakening or automatic
acceptance replay. Contract diagram relationships are unchanged.
