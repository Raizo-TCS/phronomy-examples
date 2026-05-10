# 07 Tracing

Demonstrates plugging a custom tracer into phronomy.

## Purpose

Show how to implement `Phronomy::Tracing::Base` and attach it globally via
`Phronomy.configure`. The `ConsoleTracer` prints span start/end events with
elapsed time, making the graph's execution flow visible.

## Phronomy Features

| Feature | Usage |
|---------|-------|
| `Phronomy::Tracing::Base` | Interface for custom tracers |
| `Phronomy.configure { \|c\| c.tracer = ... }` | Global tracer registration |
| `trace(name, **attrs) { \|span\| ... }` | Instrumentation point in graph nodes |

## How to Run

```bash
bundle exec ruby 07_tracing/run.rb
```

## Expected Output (approximate)

```
=== Tracing Example ===

[SPAN START] graph.invoke  input="..."
  [SPAN START] node.render_prompt
  [SPAN END]   node.render_prompt  elapsed=0.001s
  [SPAN START] node.generate_code
  [SPAN END]   node.generate_code  elapsed=1.234s
[SPAN END]   graph.invoke  elapsed=1.237s

--- Generated Code ---
puts "Hello, World!"
```
