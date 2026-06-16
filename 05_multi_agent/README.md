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
| `Phronomy::Agent::Context::Capability::Base` | Wraps sub-agents as callable tools |
| `tools` DSL | Registers sub-agent tools on the orchestrator |

## Agents and Tools

| Class | Type | Role |
|-------|------|------|
| `ResearcherAgent` | Agent | Lists key bullet points on a given topic |
| `WriterAgent` | Agent | Writes a technical blog post from given instructions |
| `ResearchTool` | Tool | Wraps `ResearcherAgent` as a callable tool |
| `WriteTool` | Tool | Wraps `WriterAgent` as a callable tool |
| `OrchestratorAgent` | Agent | Uses `ResearchTool` and `WriteTool` to fulfil the task |

## File Structure

| File | Purpose |
|------|---------|
| `run.rb` | Entry point; invokes `OrchestratorAgent` with the task |
| `agents.rb` | Defines all agents and tool wrappers |

## How to Run

```bash
bundle exec ruby 05_multi_agent/run.rb
```

## Expected Output (approximate)

```
=== Multi-Agent Example ===
Task: Write a technical blog post about Ruby 3.4 new features.

  [ResearchTool] topic=Ruby 3.4 new features
  [WriteTool] writing article...

--- Final Article ---
Ruby 3.4 introduces several exciting features...
```
