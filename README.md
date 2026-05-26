# phronomy-examples

Runnable examples for the [phronomy](https://github.com/Raizo-TCS/phronomy) gem.

## Setup

```bash
bundle install
```

## LLM Configuration

All examples load LLM settings from `shared/llm_config.rb`.  
Edit that file to switch providers or models.

## Running an example

```bash
bundle exec ruby 01_basic_chain/run.rb
```

## Examples

| # | Directory | What it demonstrates |
|---|-----------|----------------------|
| 01 | `01_basic_chain/` | Minimal Workflow pipeline using `WorkflowContext` and `Workflow.define` |
| 02 | `02_react_agent/` | ReAct Agent with custom tools |
| 03 | `03_state_graph/` | Stateful branching graph |
| 04 | `04_interrupt_resume/` | Human-in-the-loop with interrupt/resume |
| 05 | `05_multi_agent/` | Multi-Agent LLM-driven coordination (Agent-as-Tool) |
| 06 | `06_guardrails/` | Input and output guardrails |
| 07 | `07_tracing/` | Custom span-based tracer |
| 08 | `08_mcp_tool/` | MCP server tool integration |
| 09 | `09_rails_chat/` | Rails web chat app using `Phronomy::Agent` with manually persisted conversation history (DB-backed via `PhronomyMessage`) |
| 14 | `14_code_review/` | **Comprehensive pipeline** — Guardrail, Splitter, Graph, Parallel branches, Interrupt/Resume, PromptTemplate, Agent (streaming), OutputGuardrail, Eval (LLMJudge), Tracing |
| 16 | `16_before_completion_hook/` | Global / class / instance `before_completion` hooks — logging, param overrides |
| 17 | `17_multi_agent_handoff/` | Hub-and-spoke routing with `Phronomy::Agent::Runner` — triage → specialist handoff |
| 18 | `18_rails_agent_job/` | Rails 8 + ActionCable real-time streaming via `Phronomy::Rails::AgentJob` |
| 19 | `19_trust_pipeline/` | Trustworthy output via Citation Tracking + Self-Review Loop + Confidence Gate |
| 20 | `20_cve_scanner/` | Rails 8 Web UI — CVE vulnerability scanning + remediation with CHECK LOOP / REMEDIATION LOOP, interrupt/approve gates, ActionCable real-time streaming |

## 09: Rails Chat (`09_rails_chat/`)

A full Rails web app that integrates phronomy as the conversation engine.

- `ChatAgent < Phronomy::Agent::Base` with a `CurrentTimeTool < Phronomy::Tool::Base`
- DB-backed conversation history via `PhronomyMessage` (application-managed persistence)
- `MessagesController#create` loads history with `PhronomyMessage.load_messages(thread_id)`,
  calls `ChatAgent.new.invoke(content, messages: messages, thread_id: thread_id)`,
  then saves the result with `PhronomyMessage.save_messages(thread_id, result[:messages])`
- Configured in `config/initializers/phronomy.rb`

### Run it

```bash
cd 09_rails_chat
bundle install
bin/rails db:prepare
bin/rails server -p 4567
```

Then open http://localhost:4567/.

## 14: AI Code Review Pipeline (`14_code_review/`)

A comprehensive example that exercises the majority of phronomy's features in a
single CLI pipeline.  Supply a Ruby source file and the pipeline:

1. **InputGuardrail** — rejects invalid/missing files before any LLM call
2. **Splitter** — splits large files into chunks with `RecursiveSplitter`
3. **Graph + Parallel branches** — runs Security / Performance / Readability / Abstraction agents concurrently via application-level `Thread.new` (see pipeline.rb note)
4. **Interrupt/Resume** — pauses after reviews so you can choose which area to fix
5. **PromptTemplate** — formats the improvement prompt from variables
6. **Agent (streaming)** — generates improved code with real-time token output
7. **OutputGuardrail** — validates that the improved code contains a code block
8. **Eval (LLMJudge)** — scores review quality and improvement quality out of 10
9. **Tracing** — measures and prints elapsed time for every pipeline stage

### Run it

```bash
bundle exec ruby 14_code_review/run.rb
# When prompted, enter: 14_code_review/sample.rb
```

`sample.rb` is a demo file with intentional Security, Performance, and Readability issues.
