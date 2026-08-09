# 28 — Filters: explicit trust boundaries

Filters are public transformation/blocking hooks around Agent execution.

The example covers three distinct boundaries:

```text
user input
   ↓ input Filter
Agent / LLM
   ↓
Tool call
   ↓ tool-result Filter
LLM follow-up
   ↓ output Filter
application
```

## Public APIs demonstrated

Instance-specific policy:

```ruby
agent.add_input_filter(filter)
agent.add_output_filter(filter)
agent.add_tool_result_filter(ToolClass, filter) # scoped instance filter
```

Class-level reusable policy:

```ruby
input_filter filter
output_filter filter
tool_result_filter filter
```

A filter can transform a value or stop the boundary with `block!`, which raises
`Phronomy::FilterBlockError`.

The example deliberately avoids private Agent preparation APIs. Tool-result
filtering is demonstrated by running a real Agent tool call and inspecting the
public `:tool_result` lifecycle event.
