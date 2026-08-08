# 15 Rails Secure Chat App

A Rails application showcasing four NIST AI RMF trustworthy-AI enhancements
built on phronomy stateful Agent.

## Purpose

Demonstrate enterprise-grade patterns for an AI chat interface:
input guardrails, caller identity propagation, async conversation summarization,
and automatic TTL-based memory clearing.

## Phronomy Features

| Feature | Class / API | Role |
|---------|------------|------|
| A - Blocking Filters | `Filter::PromptInjectionFilter` | Blocks prompt injection attempts |
| A - Blocking Filters | `Filter::Base` (PII pattern) | Blocks emails, phone numbers, credit cards, My Number |
| B - Caller identity | `Agent::Base config: { user_id: }` | Propagates session UUID to tracer spans |
| C - Async summarization | `SummarizationGraph` + `invoke_async` + `workflow.signal` | Non-blocking EventLoop-safe summarization |
| D - TTL clear | `session[:last_agent_activity_at]` + `agent.clear_transcript!` | Auto-clears transcript when idle exceeds `PHRONOMY_MEMORY_TTL` |
| D - Explicit clear | `agent.clear_transcript!` | Delete Chat button clears transcript immediately |

## How to Run

```bash
cd 15_rails_secure_chat
bundle install
bundle exec rails db:create db:migrate
bundle exec rails server -p 3002
```

Then open `http://localhost:3002` in a browser.

## Key Files

| File | Description |
|------|-------------|
| `app/agents/secure_chat_agent.rb` | `SecureChatAgent` with PromptInjection + PII guardrails |
| `app/graphs/summarization_graph.rb` | Async Workflow: `invoke_async` fires LLM; `:summary_done` signal advances state |
| `app/controllers/conversations_controller.rb` | `Agent.create/load`, `agent.transcript`; destroy validates `session[:agent_id]` |
| `app/controllers/messages_controller.rb` | `Agent.load` + TTL check + `agent.invoke` |
| `app/controllers/summaries_controller.rb` | Loads transcript, invokes `SummarizationGraph` |
| `config/initializers/phronomy.rb` | LLM settings, `PhronomyStore` (InMemory persistence), TTL constant |

## Multi-User Behaviour

Each browser session receives an independent `user_id` (UUID) and `agent_id`.
Open the app in a normal tab (User A) and a private window (User B) to verify
that sessions are fully isolated via separate `Persistence::InMemory` agent entries.

## Running the Scenario Test

A headless-Chrome scenario test verifies all four features automatically:

```bash
bundle exec ruby scenario/multi_user_test.rb
```

Screenshots are saved to `scenario/evidence/`.
