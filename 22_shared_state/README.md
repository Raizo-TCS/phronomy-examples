# 22 Shared State - Collaborative Code Review Team

Three specialist Agents share findings while the application controls how much
shared information enters each LLM input. Phronomy owns Agent execution, Tool
exchanges, context selection, coordination cycles, and when aggregation runs.
The application owns the finding records, search Tools, and final report format.

For example, the security reviewer searches findings about a file, reads a
bounded page, and records a new issue without loading the whole shared store.

## Review lifecycle

The team runs reviewers in order and preserves their findings between cycles.
Each reviewer retrieves selected findings and writes through an application Tool.
Every team invocation constructs its own store, policies, and derived reviewers.

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
| `write_finding` | `content` | Application store write and the existing acknowledgement |

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

The implementation uses public Phronomy extension points. `SharedState.sharing`
and `SharedState::Binding` connect application Tools and records; `Agent.with_tools`
and `context_policy` create isolated reviewer definitions. The Context contract's
`input_token_limit`, `with_input_token_limit`, and protected `estimate_tokens`
retain the existing DefaultPolicy selection and token-estimation mechanisms.
No private SharedState hook, TokenBudget, or TokenEstimator is referenced.

This example requires the **public sharing and Context budgeting APIs in
Phronomy 0.33.0 or later**. The shared dependency and all seven lockfiles select
the published 0.33.0 gem. Loading Example 22 against an older core fails with an
explicit configuration error.

This is invocation-local retrieval, not a durable Worker protocol. The provider
closes its store after aggregation or an execution failure. It must be created
anew for each invocation. Ordinary Agent approval waits keep the invocation and
store open; this example adds no cross-process restore operation.

## Ownership and composition

The application composes the review session while framework contracts execute
its Agents and select their LLM inputs. Session resources are independent even
when the same application team object is invoked again.

For example, two calls to `CodeReviewTeam#invoke` create two `ReviewSharing`
providers. Each provider binds its store to the derived reviewers' policies and
read/write Tools; neither call changes `StructureAnalyst` or the other original
Agent classes. The recorded author labels and three-cycle report stay the same.

| Application component | Responsibility | Public framework connection |
|---|---|---|
| `CodeReviewTeam` in `team.rb` | Compose a fresh session and format its report | SharedState configuration and `invoke` |
| `ReviewSharing` | Bind member policies and scope shared resources | `Agent.with_tools`, `context_policy`, `SharedState::Binding` |
| `ReviewFindingStore` | Store immutable finding records during the invocation | Opaque application store passed to callbacks |
| `AdaptiveFindingReader` | Search and page complete stored records | Called by application Tool and Policy |
| `AdaptiveReviewContextPolicy` | Allocate retrieval room and materialize requested pages | Context budgeting helpers and `DefaultPolicy` |

The store preserves the existing `agent`, `content`, and `cycle` fields. Searches
remain case-insensitive substrings of content; this migration does not add
semantic search or change review criteria. Store records are immutable snapshots,
and aggregate output must be materialized before the provider closes the store.

## Directory access

The application requests approval before Agents inspect files. File Tools
enforce the approved directory and reject paths outside it.

For example, declining leaves directory access unapproved, and file Tools return
a denial message. The team still runs, so declining does not prevent LLM requests.
This is application-owned HITL; see `04_interrupt_resume` for framework-owned
suspension and resume.

## Run the example

Install the published framework before running this example. Shared LLM
configuration supplies the model and loaded context metadata.

For example, from the examples repository root, these commands update all seven
bundles and review the bundled sample:

```bash
unset PHRONOMY_PATH BUNDLE_GEMFILE
./scripts/update_phronomy.sh
bundle exec ruby 22_shared_state/run.rb
```

For local framework development, select a checkout explicitly with
`PHRONOMY_PATH` and repeat the dependency update. Do not commit local-path
lockfiles; published-gem verification requires `PHRONOMY_PATH` to be unset.

An optional argument selects another directory:

```bash
bundle exec ruby 22_shared_state/run.rb /path/to/your/ruby/project
```

For local Qwen evaluation, use the actual loaded model and context metadata:

```bash
unset PHRONOMY_CONTEXT_WINDOW
unset PHRONOMY_PATH
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
They also check isolated repeated sessions, unchanged base Agent definitions,
absence of automatic full-store injection, and cleanup after failures.

```bash
bundle exec rspec spec/adaptive_shared_state_spec.rb \
  spec/adaptive_shared_state_integration_spec.rb spec/llm_config_spec.rb
```

For live acceptance, record the loaded model/runtime/context, exit status, elapsed
time, completed cycles, finding count, and errors. Offline success does not prove
Qwen completion or review quality. Choose a sufficient explicit time budget;
the standard verifier's short timeout may not fit this multi-cycle example.
