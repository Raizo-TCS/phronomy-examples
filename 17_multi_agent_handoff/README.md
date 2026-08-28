# 17 Multi-Agent Handoff

Demonstrates `Phronomy::MultiAgent::Runner` with explicit
`Phronomy::MultiAgent::Handoff` edges.

## Purpose

A triage Agent is the `main_agent`. Two explicit Handoff objects declare the
allowed responsibility transfers to BillingAgent and TechSupportAgent. Phronomy
projects those edges into handoff tools for the active Agent; application code
does not invent a second routing/session model.

## Architecture

```text
User input
    │
    ▼
TriageAgent
    ├── Handoff ──▶ BillingAgent
    └── Handoff ──▶ TechSupportAgent
```

## Phronomy Features

| Feature | Usage |
|---|---|
| `Phronomy::MultiAgent::Runner` | Executes one multi-Agent user turn |
| `Phronomy::MultiAgent::Handoff` | Declares one allowed source → target responsibility transfer |
| `main_agent:` | Declares the initial Agent |
| `handoffs:` | Supplies the explicit Handoff graph |
| `result[:agent]` | Identifies the Agent that produced the final answer |

## How to Run

```bash
bundle exec ruby 17_multi_agent_handoff/run.rb
```
