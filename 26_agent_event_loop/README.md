# 26 — Agent EventLoop Mode

## Purpose

Demonstrates two patterns for running agents through Phronomy's cooperative `EventLoop`.
Both patterns use `c.event_loop = true` so every agent invocation is dispatched and
scheduled by the framework's event loop rather than blocking the calling thread directly.

**Pattern 1 — `Agent#invoke` via EventLoop**  
A plain `QnAAgent` (no tools) answers a simple arithmetic question.
Calling `invoke` on the agent routes the FSM through `AgentFSM` automatically;
the event loop drives execution to completion before returning.

**Pattern 2 — `invoke_async` + `Task#map` inside a Workflow**  
A `TranslationAgent` is embedded as a child FSM inside a `TranslationWorkflow`.
The `:translate` entry action calls `invoke_async`, which returns a `Task`.
`Task#map` transforms the agent result into an updated `WorkflowContext`; the
`FSMSession` picks this up via the `:action_completed` transition and proceeds
to the `:done` state.

## Phronomy Features

| Feature | Class / API |
|---|---|
| EventLoop configuration | `Phronomy.configure { c.event_loop = true }` |
| Agent base class | `Phronomy::Agent::Base` |
| Async agent invocation | `Agent#invoke_async` → `Phronomy::Task` |
| Task transformation | `Task#map` |
| Workflow definition | `Phronomy::Workflow.define` |
| Workflow context | `Phronomy::WorkflowContext` (fields: `:replace`) |
| Output validation helper | `OutputValidator.validate` |

## How to Run

LM Studio (or another OpenAI-compatible server) must be running and configured
in `shared/llm_config.rb`.

```bash
cd /home/raizo-tcs/ruby_ai_agent_framework/phronomy-examples
export PATH="$HOME/.local/share/gem/ruby/3.2.0/bin:$PATH"
bundle exec ruby 26_agent_event_loop/run.rb
```

## Expected Output (approximate)

```
=== 26 Agent EventLoop Mode ===

--- Pattern 1: Agent#invoke via EventLoop ---
Q: What is 2 + 2? Reply with just the number.
A: 4
Elapsed: 843ms

--- Pattern 2: Agent as child FSM inside a Workflow ---
Query:  Translate "hello" to Japanese
Answer: konnichiwa (or equivalent Japanese greeting)
Status: done
```

Elapsed time varies by network and model; the exact translation may differ slightly
depending on the model's output.
