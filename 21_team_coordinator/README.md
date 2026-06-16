# 21 Team Coordinator

## Purpose

Demonstrates `Phronomy::MultiAgent::TeamCoordinator` — the "Agent teams" coordination pattern.

A coordinator LLM agent breaks a blog topic into sections using `enqueue_task`, then a pool of two worker agents writes each section. Workers carry forward their conversation history across assignments so tone and style remain consistent throughout the post.

## Phronomy Features

| Feature | Class / API used | Role |
|---|---|---|
| Worker agent | `Phronomy::Agent::Base` (`BlogSectionWriter`) | Writes one blog section per invocation; accumulates style context across assignments |
| Team coordinator | `Phronomy::MultiAgent::TeamCoordinator` (`BlogWritingTeam`) | Breaks the topic into 4–5 sections via `enqueue_task`, dispatches them to the worker pool, and calls `finalize` when done |
| Worker pool | `pool size: 2, agent: BlogSectionWriter` | Two worker instances share the writing load concurrently |
| Result aggregation | `aggregate` block | Collects each assignment's worker ID, task description, and LLM-generated content into a single `{ sections: [...] }` hash |
| Streaming progress | `TeamCoordinator#stream` | Yields `:task_completed` / failure events as each section finishes, enabling real-time progress output |
| Output validation | `OutputValidator.validate` | Asserts that at least 4 sections were produced and each contains ≥ 50 characters of content |

## How to Run

```bash
cd /home/raizo-tcs/ruby_ai_agent_framework/phronomy-examples
export PATH="$HOME/.local/share/gem/ruby/3.2.0/bin:$PATH"
bundle exec ruby 21_team_coordinator/run.rb
```

> An OpenAI-compatible LLM server (e.g. LM Studio) must be running and configured in `shared/llm_config.rb`.

## Expected Output

```
=== 21 Team Coordinator ===

Topic: "Concurrency in Ruby: Threads, Fibers, and Ractors"

[Coordinator] Planning blog sections...

✓ [Worker 0] Write the Introduction section
  Ruby has long supported multiple concurrency primitives. In this post we...

✓ [Worker 1] Write the Core Concepts section
  Threads give true OS-level parallelism but share memory, while Fibers are...

✓ [Worker 0] Write the Code Example section
  The following snippet shows a simple Fiber-based producer-consumer pattern...

✓ [Worker 1] Write the Practical Tips section
  Prefer Fibers for cooperative I/O scheduling and reach for Ractors only when...

✓ [Worker 0] Write the Conclusion section
  Choosing the right concurrency tool in Ruby depends on your workload. Thread...


=== Final Blog Post: 5 sections ===

--- Section 1 [Worker 0] ---
Write the Introduction section. Cover: <key points>

<full section text>

--- Section 2 [Worker 1] ---
...
```

Each `✓` line appears as a section completes. Worker IDs (`0` or `1`) reflect which pool member handled the task. The final block prints all sections in order with their full LLM-generated content.
