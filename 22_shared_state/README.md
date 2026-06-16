# 22 Shared State — Collaborative Code Review Team

Demonstrates `Agent::SharedState` — the "Shared state" coordination pattern
(Anthropic multi-agent blog, Pattern 5).

Three specialist reviewer agents collaborate through a shared `KnowledgeStore` to
produce a multi-perspective code review of a Ruby codebase. There is no central
coordinator: each agent reads what peers have already found, then writes its own
findings. Subsequent agents in the same cycle immediately see findings written by
earlier agents.

A human-in-the-loop gate asks for directory-access approval before any LLM call is
made.

## Purpose

Show how multiple agents with different expertise angles can collectively build up
knowledge through a shared store, with a team-level coordination protocol, per-agent
instruction overrides, and a custom aggregation step.

## Phronomy Features

| Feature | Usage |
|---------|-------|
| `Phronomy::Agent::SharedState` | Base class for the review team |
| `coordination` DSL | Defines the shared-store protocol given to every member |
| `member` DSL | Declares `StructureAnalyst`, `SecurityAuditor`, `QualityReviewer` |
| `member instruction:` option | Adds a per-agent focus hint without changing the agent's own instructions |
| `max_cycles` DSL | Hard cap of 3 review cycles |
| `aggregate` DSL | Groups findings by agent and formats a report |
| Auto-injected tools | `read_store` and `write_finding` added to every member at runtime |
| Human-in-the-loop | `DirectoryAccess.ask_user!` prompts once before LLM invocations |

## Agents

| Agent | Role |
|-------|------|
| `StructureAnalyst` | Class/module responsibilities, coupling, design patterns |
| `SecurityAuditor` | SQL injection, hardcoded credentials, disabled SSL, missing validation |
| `QualityReviewer` | Code duplication, magic numbers, overly long methods, missing error handling |

## Custom Tools

| Tool | Description |
|------|-------------|
| `ListFilesTool` | Lists all `*.rb` files under the approved directory (relative paths) |
| `ReadFileTool` | Reads a single file by the relative path returned by `list_files` |

Both tools refuse to operate until `DirectoryAccess.ask_user!` has been approved.
`ReadFileTool` also rejects path-traversal attempts outside the approved directory.

## How to Run

```bash
# Review the bundled sample files in 22_shared_state/data/
bundle exec ruby 22_shared_state/run.rb

# Review a custom directory
bundle exec ruby 22_shared_state/run.rb /path/to/your/ruby/project
```

The program will pause for user input before contacting the LLM:

```
[Human-in-the-Loop] Agents will read source files under:
  /path/to/your/ruby/project
  Allow directory access? [y/N]:
```

## Expected Output (approximate)

```
=== Shared State Code Review Example ===
Target : /path/to/22_shared_state/data

[Human-in-the-Loop] Agents will read source files under:
  /path/to/22_shared_state/data
  Allow directory access? [y/N]: y
  => Approved.

[ StructureAnalyst ]
  (cycle 1) UserManager mixes persistence and business logic — consider separating
            into repository and service layers.
  (cycle 1) ApiClient is tightly coupled to a hardcoded base URL.

[ SecurityAuditor ]
  (cycle 1) user_manager.rb line 14: password stored in plain text.
  (cycle 1) api_client.rb line 8: SSL verification disabled (`verify_ssl: false`).

[ QualityReviewer ]
  (cycle 1) report_generator.rb: method `build_report` is 87 lines — split by concern.
  (cycle 1) Magic number `42` used in user_manager.rb line 31 without explanation.

--------------------------------------------------
Cycles completed : 1
Terminated by    : max_cycles
Total findings   : 6
```

## Implementation Steps

1. Define three `Phronomy::Agent::Base` subclasses — `StructureAnalyst`,
   `SecurityAuditor`, `QualityReviewer` — each with role-scoped instructions and
   `tools ListFilesTool, ReadFileTool`.
2. Implement `ListFilesTool` and `ReadFileTool` as
   `Phronomy::Agent::Context::Capability::Base` subclasses; guard both with
   `DirectoryAccess` approval and reject path traversal in `ReadFileTool`.
3. Create `CodeReviewTeam < Phronomy::Agent::SharedState` using:
   - `coordination` — shared-store protocol sent to every member
   - `member StructureAnalyst`
   - `member SecurityAuditor, instruction: "..."` — per-agent focus hint
   - `member QualityReviewer, instruction: "..."`
   - `max_cycles 3`
   - `aggregate` block that groups findings by `:agent`, formats a report string,
     and returns `{ report:, count: }`.
4. At startup, call `DirectoryAccess.ask_user!(target_dir)` before invoking the team.
5. Invoke with a prompt string; display the formatted report and metadata.
