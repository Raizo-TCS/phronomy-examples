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

### Opt-in LM Studio / GPT-OSS evaluation

The default mode is `native`, which retains the ordinary request and output
validation behavior. For an explicitly selected LM Studio endpoint running
`openai/gpt-oss-20b`, this example also provides a local compatibility profile:

```bash
PHRONOMY_TRACING_LLM_MODE=lmstudio_gpt_oss \
PHRONOMY_MODEL=openai/gpt-oss-20b \
PHRONOMY_PROVIDER=openai \
PHRONOMY_BASE_URL=http://192.168.122.1:1234/v1 \
PHRONOMY_CONTEXT_WINDOW=131072 \
bundle exec ruby 07_tracing/run.rb
```

Use the existing `PHRONOMY_API_KEY` configuration (or a non-secret placeholder
if the local server does not require authentication). The context declaration
describes the loaded model; it does not change the server's context setting.

`llm_compatibility.rb` registers a named protocol using RubyLLM 2.0's public
`Provider.protocol` and `Protocols::ChatCompletions#render_payload` extension
points. It selects that protocol through `openai_protocol` and adds only
`repeat_penalty: 1.0` to the generation payload. Prompt, model, tracing,
response parsing and usage handling retain their existing paths. No existing
RubyLLM method is monkey-patched, and Phronomy's backend is unchanged.

In this opt-in mode, transport retries and output-validation retries are
disabled. An HTTP error or invalid output fails the process after one attempt.
The mode is selected at process startup; run this example in its own process.
Its RubyLLM configuration is process-wide and is not a per-Agent override.
Other examples do not load this compatibility file. An unknown mode or an
incompatible model/provider configuration raises an error before generation.

This is an application-selected evaluation setting, not automatic capability
detection or a generic GPT-OSS fix. Both application trials below requested
`repeat_penalty: 1.0`, with model `openai/gpt-oss-20b`, context `131072` and
CUDA12 runtime `2.60.0`.

| Application trial (Asia/Tokyo) | Observed result | Evidence boundary |
|---|---|---|
| 2026-10-21 | Exit 1; PEG rejection; no delivered result | HTTP 400 inferred from SDK mapping; raw generation response and complete model output were not captured |
| 2026-10-22 | One POST, zero SDK retries, directly captured HTTP 200, exit 0, Go output and four error-free span pairs | One successful trial with an external HTTP observer; model input and completed output text were logged |

The successful trial used examples base `8a03a545f61812a9ba6fa05f86575eabeafc0e0c`
plus the five-file candidate (tree `7bd5357963a756e05f54c982ed87368f5cdb978b`)
and core `e424728f8d8924d4e3774661380576a274b32ad5`. This documentation update
follows that trial; the named tree identifies the tested snapshot.

The SDK-rendered prompt date changed from 2026-10-21 to 2026-10-22. Actual
model input was captured only in the successful trial, and internal sampling
and cache state were not held constant. The server-effective penalty,
complete pre-PEG token sequence, earlier failure cause and recurrence
resolution remain unverified. In particular, one failure and one success with
the same requested override do not demonstrate that this setting fixes PEG
errors. Preserve the distinction between this single-trial acceptance and
general reliability. The diagnostic observer remains outside the repository.

Run the offline request/tracing/error-path regression with:

```bash
bundle exec rspec spec/tracing_llm_compatibility_spec.rb spec/execution_examples_spec.rb
```

The live acceptance requires one generation request containing the override,
a successful process with Go Hello World output, and balanced span start/end
events without errors. HTTP 200 alone is insufficient. A single successful run
does not establish reliability or resolve Example 22's separate acceptance.

References: [RubyLLM protocol extensions](https://rubyllm.com/custom-providers/)
and [LM Studio Chat Completions parameters](https://lmstudio.ai/docs/developer/openai-compat/chat-completions).

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
