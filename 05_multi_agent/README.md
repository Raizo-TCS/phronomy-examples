# 05 Multi-Agent (LLM-Driven Coordination)

Demonstrates the "Agent-as-Tool" pattern for dynamic multi-agent orchestration.

## Purpose

Wrap specialist sub-agents as tools so that an orchestrator agent can decide
autonomously when and how to call them — instead of following a hardcoded
execution order in a workflow.

## Phronomy Features

| Feature | Usage |
|---------|-------|
| `Phronomy::Agent::Base` | Defines specialist and orchestrator agents |
| `Phronomy::Tool::Base` | Wraps sub-agents as callable tools |
| `tools` DSL | Registers sub-agent tools on the orchestrator |

## Agents and Tools

| Class | Type | Role |
|-------|------|------|
| `ResearcherAgent` | Agent | Lists key bullet points on a given topic |
| `WriterAgent` | Agent | Writes a technical blog post from given instructions |
| `ResearchTool` | Tool | Wraps `ResearcherAgent` as a callable tool |
| `WriteTool` | Tool | Wraps `WriterAgent` as a callable tool |
| `OrchestratorAgent` | Agent | Uses `ResearchTool` and `WriteTool` to fulfil the task |

## File Structure

| File | Purpose |
|------|---------|
| `run.rb` | Entry point; invokes the orchestrator once and validates collaboration |
| `agents.rb` | Defines all agents and tool wrappers |
| `validation.rb` | Checks the research-to-writer handoff using public result messages |
| `budget.rb` | Allocates capacity and connects output configuration to Context selection |

## How to Run

```bash
bundle exec ruby 05_multi_agent/run.rb
```

## Expected Output (approximate)

```
=== Multi-Agent Example ===
TaskResult: Write a technical blog post about Ruby 3.4 new features.

  [ResearchTool] topic=Ruby 3.4 new features
  [WriteTool] writing article...

--- Final Article ---
Ruby 3.4 introduces several exciting features...
```

## Capacity-aware input and output allocation

Each specialist and the orchestrator use the same Example 05 allocation rule.
Before every LLM call, the configured Phronomy Adapter supplies the registered
context capacity. The example allocates one quarter to output and one sixteenth
to a safety margin, with the remainder available for input. A smaller positive
output limit in RubyLLM's model registry further limits the requested output.

| Registered context | Output cap | Safety margin | Input allowance |
| --- | --- | --- | --- |
| 8192 | 2048 | 512 | 5632 |
| 131072 | 32768 | 8192 | 90112 |

The table assumes no smaller independent output limit. These are maximum
allowances, not required generation lengths or guarantees of sufficient reasoning
capacity. Prompts still request five research bullets and a 250-350-word article.

The `before_llm_input` hook returns a public `LLMInputPatch` setting the allocated
`max_output_tokens`. `Example05InputPolicy` reserves that actual output cap and the
margin, accounts for Tool framing, and delegates selection to `DefaultPolicy`.
A final estimate checks the selected input. Required input and Tool exchanges are
not silently truncated; oversized mandatory input fails before generation.
Logical transcript history is retained even when optional turns are not sent.

`max_output_tokens` alone does not subtract from Phronomy's input budget. The
example explicitly connects the two allocations through its hook and policy.
Model capability metadata comes from shared configuration and the SDK registry;
Phronomy does not automatically query every server for its current load settings.
For a custom endpoint, set `PHRONOMY_CONTEXT_WINDOW` to the actual loaded capacity
when shared configuration cannot discover it. Unknown context or invalid metadata
causes an explicit error; the example never guesses a context size. A missing
independent output limit remains unknown, so the ratio cannot guarantee provider
acceptance. Changes to model load settings require corresponding metadata updates.

## Collaboration acceptance

The research Tool rejects blank final answers. The write Tool requires a separate
`research_notes` argument, copied verbatim from the research result, and includes
it in the writer's prompt. Before declaring success, the entry point checks Tool
call IDs and transcript order, complete notes transfer, and a completed Writer
result containing at least 300 characters. The application publishes the last
verified Writer result verbatim. The orchestrator reports completion; its final
response remains in the transcript and does not replace the Writer article.
This avoids relying on the model to copy the same article byte-for-byte.

The entry point does not automatically rerun the task after validation failure.
Scoped Agents are released on success and failure. This verifies allocation and
content transfer, not factual accuracy: research uses the model's knowledge and
does not consult external sources.
