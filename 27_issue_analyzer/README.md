# 27 GitHub Issue Analyzer

## Purpose

Fetches all GitHub Issues from a repository using the `gh` CLI and classifies
each one on two independent axes using an LLM-backed Phronomy agent:

- **Axis 1 — Issue Type (WHAT):** The nature of the work (Bug: Correctness,
  Feature, Architecture Decision, Testing / CI, etc. — 14 categories).
- **Axis 2 — Component (WHERE):** The structural location in the codebase
  (Runtime / Scheduler / Task, Agent / FSM, Workflow / Graph, etc. — 17 categories).

The agent identifies semantically meaningful `(type, component)` pairs for each
issue — **not** the cross-product of independent type and component lists.  One
issue with two distinct aspects produces two pairs.

Results are printed in five sections and also written to `docs/issue_analysis.csv`.

## Phronomy Features

| Feature | Class / Method | Role |
|---|---|---|
| LLM agent | `Phronomy::Agent::Base` | `IssueClassifierAgent` subclass; classifies batches of issues via structured JSON prompt |
| Runtime configuration | `Phronomy.configure` | Sets `runtime_backend = :thread` so agent invocations run in OS threads (required for blocking LLM I/O) |
| Shared LLM config | `LLMConfig::MODEL`, `LLMConfig::PROVIDER` | Provider-agnostic model and provider name loaded from `shared/llm_config.rb` |

## How to Run

**Prerequisites:**

- `gh` (GitHub CLI) installed and authenticated (`gh auth login`)
- An OpenAI-compatible LLM server running (e.g. LM Studio)
- Environment variables set as required by `shared/llm_config.rb`

```bash
# Analyze all issues (open + closed)
bundle exec ruby 27_issue_analyzer/run.rb

# Analyze open issues only
bundle exec ruby 27_issue_analyzer/run.rb --open-only

# Skip LLM calls — print unclassified skeleton output
bundle exec ruby 27_issue_analyzer/run.rb --dry-run
```

The target repository is `Raizo-TCS/phronomy` (edit the `REPO` constant in
`run.rb` to point at a different repository).

The CSV output is written to:
```
docs/issue_analysis.csv   # one row per issue × type × component triple
```

## Expected Output (approximate)

```
Fetching issues from Raizo-TCS/phronomy...
Fetched 383 issues (open: 12, closed: 371)

  Batch 1/26 (#383..369)... OK (15 classified)
  Batch 2/26 (#368..354)... OK (15 classified)
  ...
  Batch 26/26 (#15..1)... OK (15 classified)

Classification complete: 383 issues in 26 batches.

CSV written → /home/.../docs/issue_analysis.csv

════════════════════════════...
  phronomy Issue Analysis  |  Raizo-TCS/phronomy  |  <model>
  Axes: (1) Issue Type = WHAT  ×  (2) Architectural Component = WHERE
════════════════════════════...

  SECTION 1 — Issue Type Breakdown  (Axis 1: WHAT kind of issue?)
  ────────────────────────...
  Bug: Correctness / Silent Failure       47  open: 3  ████████████░░░░░░░░  62%
  Feature                                 89  open: 5  ██████████████████░░  94%
  Architecture Decision                   31  open: 1  ██████████████████░░  97%
  ...
  TOTAL (unique issues)                  383  open:12  ███████████████████░  97%

  SECTION 2 — Architectural Component Breakdown  (Axis 2: WHERE?)
  ────────────────────────...
  Agent / FSM                             72  open: 4  ██████████████████░░  94%
  Runtime / Scheduler / Task             58  open: 3  █████████████████░░░  95%
  ...

  SECTION 3 — 2D Histogram: Issue Type × Architectural Component
  Component abbreviations:
    RT  = Runtime / Scheduler / Task      EL  = EventLoop / ConcurrencyGate
    ...
                  RT   EL   CL   BP   AG   TL   OR   WF   MM   RG ...  Total
  ──────────────────────────────────────────────────────────────
  Bug:Correct       8    3    2    0   12    4    1    5    2    0 ...     47
  Feature           6    4    1    2   18    7    3   12    4    1 ...     89
  ...
  Total            58   21   15    3   72   31   18   43   22    8 ...    412

  SECTION 4 — Open Issues (12)
  ────────────────────────...
  #381  Add BlockingAdapterPool
    Labels: enhancement
    (Feature)  →  BlockingAdapterPool

  #379  ...
  ...

  SECTION 5 — Issue Volume by Period
  ────────────────────────...
  #2-50    Initial features + first bugs         49 issues  ████████████████████ 100%
  #51-100  Code quality + docs round 1           50 issues  ████████████████████ 100%
  ...
════════════════════════════...
```

Section 3 counts reflect the number of semantic `(type, component)` pairs, so
column and row totals may exceed the total number of unique issues.
