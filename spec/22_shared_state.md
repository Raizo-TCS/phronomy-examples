# spec/22_shared_state.md

## Purpose

Demonstrate the `Phronomy::Agent::SharedState` coordination pattern where three
specialist agents collaborate through a shared KnowledgeStore to produce a
multi-perspective code review report.

The example also shows **human-in-the-loop directory access approval**: before
any LLM is invoked, the user is prompted once to approve filesystem access to
the target directory. All tool calls respect this decision.

## Phronomy Features Demonstrated

- `Phronomy::Agent::SharedState` — `researchers`, `max_cycles`, `terminate_when`, `aggregate`
- `Phronomy::Tool::Base` — `ListFilesTool` (no params) and `ReadFileTool` (filename param)
- Human-in-the-loop gate (`DirectoryAccess`) — startup approval prompt, path-traversal protection
- DSL inheritance via `Class.new(superclass)` — internal mechanism used by `SharedState`
- Role-specific `instructions` keeping each agent in its analytical lane

## Files

| File | Role |
|---|---|
| `run.rb` | Entry point — defines agents and `CodeReviewTeam`, runs invocation |
| `tools.rb` | `DirectoryAccess` module + `ListFilesTool` + `ReadFileTool` |
| `data/user_manager.rb` | Sample file with SQL injection and long-method issues |
| `data/api_client.rb` | Sample file with hardcoded credentials and SSL bypass |
| `data/report_generator.rb` | Sample file with code duplication and magic numbers |

## Environment Variables Required

None. Tools read local files only; no external API calls.

## Agents

| Agent | Analytical Lens |
|---|---|
| `StructureAnalyst` | Class structure, responsibilities, design patterns |
| `SecurityAuditor` | SQL injection, hardcoded credentials, SSL bypass |
| `QualityReviewer` | Code duplication, magic numbers, long methods |

## Expected Output (approximate)

```
=== Shared State Code Review Example ===
Target : .../22_shared_state/data

[Human-in-the-Loop] Agents will read source files under:
  .../22_shared_state/data
  Allow directory access? [y/N]: y
  => Approved.

[ StructureAnalyst ]
  (cycle N) UserManager is a god-class mixing DB access with email, logging, and notification concerns.
  ...

[ SecurityAuditor ]
  (cycle N) user_manager.rb interpolates user input directly into SQL query strings, enabling SQL injection.
  ...

[ QualityReviewer ]
  (cycle N) report_generator.rb duplicates identical filter-sort-slice logic across three generate_* methods.
  ...
```

## Implementation Steps

1. `tools.rb` — implement `DirectoryAccess`, `ListFilesTool`, `ReadFileTool`
2. `data/` — create three sample Ruby files with deliberate issues
3. `run.rb` — define three agents and `CodeReviewTeam < Phronomy::Agent::SharedState`
4. Verify with `ruby -c` syntax check

## Expected Output (approximate)

```
=== Shared State Research Example ===
Topic : Rust programming language in systems software

[Human-in-the-Loop] An agent wants to search the web.
  Query : Rust Stack Overflow survey rankings 2024
  Allow? Approving once permits all subsequent searches. [y/N]: y
  => Approved. Subsequent searches will proceed automatically.

[ MarketAnalyst ]
  (cycle 1) Rust ranked #1 in the Stack Overflow 2024 'most admired language' survey for the ninth consecutive year.
  ...

[ TechAnalyst ]
  (cycle 1) Rust's borrow checker enforces aliasing rules at compile time, eliminating use-after-free with zero runtime overhead.
  ...

[ IndustryAnalyst ]
  (cycle 1) Cloudflare rewrote its HTTP proxy in Rust, reducing memory usage by 70% compared to the previous C++ implementation.
  ...

──────────────────────────────────────────────────
Cycles completed : 1
Terminated by    : terminate_when
Total findings   : 8
```

## Implementation Steps

1. Create `tools.rb`:
   - `WebSearchApproval` module with `@mutex`-guarded `@approved` flag and `request!` method
   - `WebSearchTool < Phronomy::Tool::Base` calling Google Custom Search API via `net/http`
2. Modify `run.rb`:
   - Add `require_relative "tools"`
   - Add `tools WebSearchTool` to each agent class
   - Add "use web_search before each finding" instruction to each agent's `instructions` block
3. Run syntax check: `bundle exec ruby -c 22_shared_state/run.rb`
4. Run `bash scripts/verify_examples.sh` and confirm PASS
