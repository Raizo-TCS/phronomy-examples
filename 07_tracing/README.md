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

For the current LM Studio gpt-oss setup, explicitly select its bounded
provider-output-failure policy:

```bash
PHRONOMY_BASE_URL=http://127.0.0.1:1234/v1 \
PHRONOMY_PROVIDER=openai \
PHRONOMY_MODEL=openai/gpt-oss-20b \
PHRONOMY_API_KEY=lm-studio \
bundle exec ruby 07_tracing/run_lm_studio.rb
```

This entry point requires the core `LLMAdapter::LMStudio` implementation. It
selects at most one additional request for a recognized provider output parsing
failure, with the same request JSON. The original `run.rb` keeps its default
backend. No prompt, temperature, repeat penalty, Tool or schema workaround is
introduced. The logical tracing spans remain unchanged.

The selected backend disables SDK retries in its own context, including ordinary
429/500/network retries. Unknown error envelopes fail without retry. Every
failed attempt is logged even if the second attempt succeeds. The earlier failed
HTTP envelope is unavailable, so offline tests use explicitly synthetic envelopes;
this feature does not claim the PEG root cause or recurrence is resolved.

Custom tracers that read `usage` now receive a plain counts Hash, for example
`usage[:input]` and `usage[:output]`, rather than an LLM domain object. This
example's ConsoleTracer does not inspect usage and needs no change.

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

The code-generation stage uses `task_state` to apply the Agent result. Automatic
tracing stays active; the application no longer forwards a completion signal.
