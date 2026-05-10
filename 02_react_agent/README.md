# 02 ReAct Agent

Demonstrates a ReAct-style agent with custom tools.

## Purpose

Show how `Agent::Base` drives multi-step tool calls autonomously. The agent
uses two dummy tools to look up a city's current time and weather, then
composes a concise report.

## Phronomy Features

| Feature | Usage |
|---------|-------|
| `Phronomy::Agent::Base` | DSL-based agent definition |
| `Phronomy::Tool::Base` | Custom tools callable by the LLM |
| `Agent#invoke` | Runs the ReAct loop (Thought → Action → Observation) |
| `model` / `instructions` / `tools` DSL | Agent configuration |

## Tools

| Tool | Description | Returns (dummy) |
|------|-------------|-----------------|
| `GetCurrentTimeTool` | Current time for a city | `"2026-05-06 10:00 JST"` |
| `GetWeatherTool` | Weather for a city | `"Sunny, 22°C"` |

## How to Run

```bash
bundle exec ruby 02_react_agent/run.rb
```

## Expected Output (approximate)

```
=== ReAct Agent Example ===
Query: Tell me the current time and weather in Tokyo.

--- Agent Response ---
The current time in Tokyo is 2026-05-06 10:00 JST and it is Sunny at 22°C.
```
