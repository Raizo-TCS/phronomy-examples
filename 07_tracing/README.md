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

[SPAN START] workflow.invoke  input="..."
  [SPAN START] agent.invoke
  [SPAN END]   agent.invoke  elapsed=1.234s
[SPAN END]   workflow.invoke  elapsed=1.237s

--- LLM Response ---
package main

import "fmt"

func main() {
    fmt.Println("Hello, World!")
}
```
