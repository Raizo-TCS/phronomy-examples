# 02 ReAct Agent

Demonstrates a ReAct-style agent with custom tools.

## Purpose

Show how `Agent::Base` drives multi-step tool calls autonomously. The agent
(`CityInfoAgent`) uses two dummy tools to look up a city's current time and
weather, then composes a concise report.

## Files

| File | Description |
|------|-------------|
| `run.rb` | Entry point — defines `CityInfoAgent` and invokes it |
| `tools.rb` | Tool definitions for `GetCurrentTimeTool` and `GetWeatherTool` |

## Phronomy Features

| Feature | Usage |
|---------|-------|
| `Phronomy::Agent::Base` | DSL-based agent definition |
| `Phronomy::Agent::Context::Capability::Base` | Base class for custom tools callable by the LLM |
| `Agent#invoke` | Runs the ReAct loop (Thought → Action → Observation) |
| `model` / `instructions` / `tools` DSL | Agent configuration |

## Tools

Both tools are defined in `tools.rb` and inherit from
`Phronomy::Agent::Context::Capability::Base`.

| Tool | Description | Returns (dummy) |
|------|-------------|-----------------|
| `GetCurrentTimeTool` | Current time for a city | `"The current time in Tokyo is 10:00 JST (2026-05-06)."` |
| `GetWeatherTool` | Weather for a city | `"The weather in Tokyo is Sunny, 22°C."` |

## How to Run

```bash
bundle exec ruby 02_react_agent/run.rb
```

## Expected Output (approximate)

```
=== ReAct Agent Example ===
Query: What is the current time and weather in Tokyo?

--- Agent Response ---
The current time in Tokyo is 10:00 JST (2026-05-06) and the weather is Sunny, 22°C.
```
