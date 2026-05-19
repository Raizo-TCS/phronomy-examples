# 22 Shared State — Collaborative Research

Demonstrates `Agent::SharedState` — the "Shared state" coordination pattern
(Anthropic multi-agent blog, Pattern 5).

Three peer researcher agents collaborate through a shared `KnowledgeStore`.
There is no central coordinator: each agent reads what peers have found,
then writes its own findings. Subsequent agents in the same cycle immediately
see findings written by earlier agents.

## Purpose

Show how multiple agents with different expertise angles can collectively
build up knowledge through a shared store, with configurable termination
conditions and a custom aggregation step.

## Phronomy Features

| Feature | Usage |
|---------|-------|
| `Phronomy::Agent::SharedState` | Base class for the research team |
| `researchers` DSL | Declares `MarketAnalyst`, `TechAnalyst`, `IndustryAnalyst` |
| `max_cycles` DSL | Hard cap of 3 cycles |
| `terminate_when` DSL | Stops early once 8 or more findings are collected |
| `aggregate` DSL | Groups findings by researcher and formats a report |
| Auto-injected tools | `read_store` and `write_finding` added at runtime |

## Agents

| Agent | Role |
|-------|------|
| `MarketAnalyst` | Adoption trends, ecosystem growth, business drivers |
| `TechAnalyst` | Performance, safety, design trade-offs |
| `IndustryAnalyst` | Company adoptions, production use cases |

## How to Run

```bash
# Default topic
bundle exec ruby 22_shared_state/run.rb

# Custom topic
bundle exec ruby 22_shared_state/run.rb "Go programming language"
```

## Expected Output (approximate)

```
=== Shared State Research Example ===
Topic : Rust programming language in systems software

[ MarketAnalyst ]
  (cycle 1) Rust has been the "most admired language" in Stack Overflow surveys
            for several consecutive years, signalling strong developer enthusiasm.
  (cycle 2) ...

[ TechAnalyst ]
  (cycle 1) Rust's ownership model guarantees memory safety without a garbage
            collector, eliminating entire classes of CVEs at compile time.
  ...

[ IndustryAnalyst ]
  (cycle 1) Microsoft has begun rewriting parts of the Windows kernel in Rust as
            part of its Secure Future Initiative.
  ...

──────────────────────────────────────────────────
Cycles completed : 2
Terminated by    : terminate_when
Total findings   : 8
```

## Implementation Steps

1. Define three `Phronomy::Agent::Base` subclasses with role-scoped instructions.
2. Create `TechResearchTeam < Phronomy::Agent::SharedState` using:
   - `researchers MarketAnalyst, TechAnalyst, IndustryAnalyst`
   - `max_cycles 3`
   - `terminate_when { |store| store.size >= 8 }`
   - `aggregate` block that groups findings by agent and returns `{ report:, count: }`
3. Invoke with a topic string; display the formatted report and metadata.
