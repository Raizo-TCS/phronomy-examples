# 11 Agent Streaming

Demonstrates token-level streaming from `Agent::Base#stream` with the event listener bound when the Agent instance is created.

## Purpose

Show how to receive LLM output incrementally as it is generated, printing
each token to the terminal in real time. Also illustrates the full set of
`StreamEvent` types emitted during an agent run.

## Phronomy Features

| Feature | Usage |
|---------|-------|
| `Agent::Base.new(on_event: ...); agent.stream(input)` | Token-level streaming with an Agent-lifetime listener |
| `Phronomy::Agent::StreamEvent` | Event object with `type` and `payload` |

## StreamEvent Types

| Type | Description |
|------|-------------|
| `:token` | Partial LLM output (print immediately) |
| `:tool_call` | A tool invocation was dispatched |
| `:tool_result` | Result returned by a tool |
| `:done` | Final output + usage statistics |
| `:error` | An error occurred |

## How to Run

```bash
bundle exec ruby 11_agent_streaming/run.rb
```

## Expected Output (approximate)

```
=== Agent Streaming Example ===

Query: Briefly explain what the Ruby programming language is.

Response: Ruby is a dynamic, object-oriented programming language...
(tokens appear one by one as the LLM generates them)
```
