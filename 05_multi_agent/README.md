# 05 Multi-Agent (LLM-Driven Coordination)

Demonstrates the "Agent-as-Tool" pattern for dynamic multi-agent orchestration.

## Purpose

Wrap specialist sub-agents as tools so that an orchestrator agent can decide
autonomously when and how to call them — instead of following a hardcoded
execution order in a workflow.

## Phronomy Features

| Feature | Usage |
|---------|-------|
| `Phronomy::Agent::Base` | Defines specialist and orchestrator agents |
| `Phronomy::Tool::Base` | Wraps sub-agents as callable tools |
| `tools` DSL | Registers sub-agent tools on the orchestrator |

## Agents

| Agent | Role |
|-------|------|
| `ResearchAgent` | Searches and summarises information on a topic |
| `WriterAgent` | Writes a polished article from research notes |
| `OrchestratorAgent` | Uses the above two agents as tools to fulfil the task |

## How to Run

```bash
bundle exec ruby 05_multi_agent/run.rb
```

## Expected Output (approximate)

```
=== Multi-Agent Example ===
Task: Write a short article about the Ruby programming language.

[Orchestrator calls ResearchAgent...]
[Orchestrator calls WriterAgent...]

--- Final Article ---
Ruby is a dynamic, open-source programming language...
```
