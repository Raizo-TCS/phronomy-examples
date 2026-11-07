# 22 Shared State - Collaborative Code Review Team

Three specialist Agents share findings while the application controls how much
shared information enters each LLM input. Phronomy owns Agent execution, Tool
exchanges, context selection, the shared store, and final aggregation.

For example, the security reviewer searches findings about a file, reads a
bounded page, and records a new issue without loading the whole shared store.

## Review lifecycle

The team runs reviewers in order and preserves their findings between cycles.
Each reviewer retrieves selected findings and writes through the original Tool.

For example, a finding written by the structure analyst is available to the
security auditor in the same cycle. Three reviewers over three cycles produce
nine member invocations.

| Reviewer | Focus |
|---|---|
| `StructureAnalyst` | Responsibilities, coupling, and design patterns |
| `SecurityAuditor` | Injection, credentials, transport security, and validation |
| `QualityReviewer` | Duplication, complexity, constants, and error handling |

Each member has a limit of 30 Agent-loop iterations **per invocation**, not
across all cycles. The final aggregation reads all stored findings. Pagination
does not delete stored content, but does not guarantee every reviewer reads
every finding: Agents choose their searches and pages.

## Shared retrieval and LLM context

The read Tool captures a request and the store boundary visible at execution.
The application ContextPolicy adds the retrieval page as knowledge after
accounting for the entire mandatory Tool exchange. The existing
`DefaultPolicy` selects optional history and knowledge under the same limit.

For example, two `read_store` calls return two short receipts. The next input
contains both unchanged receipts and two `shared_findings_page` knowledge items,
sharing the available retrieval budget and identified by `tool_call_id`.

| Operation | Input | Result |
|---|---|---|
| `read_store` | Optional `before_id`, `query`, `finding_id`, `content_offset` | `shared_findings_request` receipt with a snapshot boundary |
| ContextPolicy retrieval | Successful receipts matched to read Tool calls | `shared_findings_page` knowledge containing each page |
| `write_finding` | `content` | Original store write and acknowledgement |

Pages list newest records first. Pass `next_before_id` as `before_id` for older
records. `query` searches complete stored text case-insensitively; keep the same
query across pages. For truncated records, pass `id` as `finding_id` and
`next_content_offset` as `content_offset`. Offsets count Ruby characters.

The policy sizes the complete knowledge envelope, including JSON encoding.
Mandatory Tool results remain unchanged. A read before a write in one exchange
keeps its earlier snapshot boundary; a later read can see the new finding.

## Budget and compatibility

The application sets retrieval allocation; the framework selects and validates
LLM input. The policy requires known model input metadata and uses the
framework's approximate token estimates.

For example, an 8192-token limit reserves 2048 for generation and 512 as a margin,
leaving 5632 for selected input. Half the space left after mandatory input is
shared between all pending read requests; optional history may use the rest.

These ratios do not set an output-token cap or guarantee an exact tokenizer
count. Missing metadata and required inputs that cannot fit cause explicit
errors. Large `read_file` results or very large Tool batches can still exhaust
the budget; this adapter does not silently truncate them.

The adapter is evaluated against published Phronomy **0.32.0** with the repository
lockfile. `ContextPolicy` is public, but the adapter also uses private
`SharedState` hooks and token-estimation/budget helpers, including
`ContextPolicy#estimate_content`, `TokenBudget`, and `TokenEstimator`. Future versions
require compatibility tests. This is invocation-local retrieval, not a new
durable Worker protocol. It does not modify model-server PEG parsing.

## Directory access

The application requests approval before Agents inspect files. File Tools
enforce the approved directory and reject paths outside it.

For example, declining leaves directory access unapproved, and file Tools return
a denial message. The team still runs, so declining does not prevent LLM requests.
This is application-owned HITL; see `04_interrupt_resume` for framework-owned
suspension and resume.

## Run the example

Resolve the published framework using the frozen lockfile, then invoke the
example with the directory to review. Shared LLM configuration supplies the model.

For example, these commands review the bundled sample:

```bash
unset PHRONOMY_PATH
export BUNDLE_GEMFILE="$PWD/Gemfile"
BUNDLE_FROZEN=true bundle install
bundle exec ruby 22_shared_state/run.rb
```

An optional argument selects another directory:

```bash
bundle exec ruby 22_shared_state/run.rb /path/to/your/ruby/project
```

For local Qwen evaluation, use the actual loaded model and context metadata:

```bash
unset PHRONOMY_PATH PHRONOMY_CONTEXT_WINDOW
export PHRONOMY_BASE_URL=http://192.168.122.1:1234/v1
export PHRONOMY_PROVIDER=openai
export PHRONOMY_MODEL=qwen/qwen3.6-27b
bundle exec ruby 22_shared_state/run.rb
```

Approve only the intended directory. Output contains the report, completed cycles,
termination reason, and finding count. Content and duration depend on the model.

## Verification

Deterministic tests check application budgets and actual Agent/SharedState
execution with HTTP responses replaced. Real-model acceptance separately checks
whether the model uses retrieval correctly and completes the review.

For example, the integration tests execute multiple reads in one exchange,
recover an escaped long finding, and run three reviewers over three cycles.

```bash
bundle exec rspec spec/adaptive_shared_state_spec.rb \
  spec/adaptive_shared_state_integration_spec.rb spec/llm_config_spec.rb
```

For live acceptance, record the loaded model/runtime/context, exit status, elapsed
time, completed cycles, finding count, and errors. Offline success does not prove
Qwen completion or review quality. Choose a sufficient explicit time budget;
the standard verifier's short timeout may not fit this multi-cycle example.
