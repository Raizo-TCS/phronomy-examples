# 17 Multi-Agent Handoff

Demonstrates `Phronomy::Agent::Runner` for hub-and-spoke multi-agent routing.
A triage agent receives all user queries and automatically transfers them to the
appropriate specialist via a handoff tool call.

## Purpose

Show how `Runner` coordinates multiple agents without hardcoding control flow
in application code. The LLM decides when and where to hand off.

## Architecture

```
User input
    │
    ▼
TriageAgent  ──transfer_to_billing_agent──────▶  BillingAgent
             ──transfer_to_tech_support_agent──▶  TechSupportAgent
```

Handoff tools (`transfer_to_billing_agent`, `transfer_to_tech_support_agent`)
are generated automatically by `Runner` from the `routes:` configuration.

## Phronomy Features

| Feature | Usage |
|---------|-------|
| `Phronomy::Agent::Runner` | Orchestrates routing between agents |
| `routes:` hash | Declares hub-and-spoke topology |
| `result[:agent]` | Identifies which agent answered |
| Auto-generated handoff tools | LLM uses them to transfer conversation |

## Scenarios

| # | Query type | Expected handler |
|---|-----------|-----------------|
| 1 | Billing dispute | `BillingAgent` |
| 2 | Software crash | `TechSupportAgent` |
| 3 | General question | `TriageAgent` (no handoff) |

## How to Run

```bash
bundle exec ruby 17_multi_agent_handoff/run.rb
```

## Files

| File | Description |
|------|-------------|
| `run.rb` | Entry point — Runner setup and 3 scenarios |
| `agents.rb` | `TriageAgent`, `BillingAgent`, `TechSupportAgent` |
