# Example 05: capacity-aware Agent-as-Tool coordination

## Purpose

Demonstrate LLM-driven research and writing with scoped specialist Agents.
Example 05 owns input/output allocation instead of hardcoding a small output cap.
Phronomy still owns model operations, Context selection and Agent lifetimes.

## Phronomy features

Use Agent definitions, Tool parameters, `Agent.open_scope`, `invoke_async`,
`LLMAdapter#input_budget`, `before_llm_input` / `LLMInputPatch`, and ContextPolicy's
public selection helpers. No core API changes are required.

## Allocation rule

For a known registered context window W, request floor(W / 4) output tokens,
limited further by a positive RubyLLM registry output limit when one is known.
Reserve max(floor(W / 16), 1) tokens as a safety margin and use the remainder for
input. Each Agent call re-reads metadata; ContextPolicy reserves the exact output
cap in that call's model configuration. Unknown context or invalid capacity
fails explicitly before a generation request. Unknown output capacity means the
example's ratio is the only known output bound, not an assertion of provider support.

Examples without a smaller independent output limit:

| Context | Output cap | Margin | Input allowance |
| --- | --- | --- | --- |
| 8192 | 2048 | 512 | 5632 |
| 131072 | 32768 | 8192 | 90112 |

The policy accounts for the complete Tool-definition array, delegates history
selection to DefaultPolicy, then checks the selected canonical input estimate.
It preserves required items and complete Tool exchanges. If they cannot fit,
it fails instead of truncating mandatory input or reducing the output allowance.
These estimates and ratios are application policy, not a precise tokenizer or
an automatically discovered optimal budget.

## Acceptance

- Every actual generation request carries the allocated output cap.
- Optional history can be excluded from provider input without deleting the
  logical transcript. Oversized mandatory input is rejected before HTTP.
- Research must return nonblank final-answer text; reasoning is not an answer.
- The writer receives the complete research result as a separate argument.
- The completed transcript links an earlier research result to the write call;
  the last completed Writer result is published verbatim as the final article
  of at least 300 characters. The orchestrator response remains in the result
  transcript but is not the publication source.
- Missing, blank, substituted or out-of-order research is not accepted.
- Formatting changes or replacement text in the orchestrator response do not
  alter the published Writer result. No model response is rewritten.
- The entry point does not automatically rerun the task after failure.
- All owned Agents are released on success and failure.

## Implementation and verification

Read capacity through the configured Phronomy Adapter. Model metadata still comes
from the shared configuration and RubyLLM registry; this example does not add
server-specific discovery. For a custom endpoint, configure the actual loaded
window through PHRONOMY_CONTEXT_WINDOW if it cannot be discovered by shared setup.
Read an optional independent output limit through RubyLLM's public Model metadata;
Phronomy's input-budget API does not expose that separate capability.

Test multiple windows, output limits, unknown metadata, mandatory/optional input,
and the research-to-writer handoff using offline HTTP fixtures. Then record one
live Example 05 run with the configured model. Successful transport and handoff
do not establish factual correctness: the researcher does not verify sources.
