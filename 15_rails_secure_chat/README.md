# 15 Rails Secure Chat App

A Rails application showcasing four NIST AI RMF trustworthy-AI enhancements
built on top of phronomy.

## Purpose

Demonstrate enterprise-grade security features for an AI chat interface:
input guardrails, caller identity propagation, encrypted state checkpoints,
and automatic TTL-based memory purging.

## Phronomy Features

| Feature | Class / API | Role |
|---------|------------|------|
| **A — Guardrails** | `Guardrail::Builtin::PromptInjectionDetector` | Blocks prompt injection attempts |
| **A — Guardrails** | `Guardrail::Builtin::PIIPatternDetector` | Blocks emails, phone numbers, credit cards, My Number |
| **B — Caller identity** | `Agent::Base config: { user_id: }` | Propagates session UUID to tracer spans |
| **C — Encrypted checkpoint** | `StateStore::Encryptor::ActiveSupport` | AES-256-GCM encryption of graph state in DB |
| **D — TTL purge** | `ConversationManager ttl:` | Auto-deletes messages older than the configured threshold |
| **D — Explicit purge** | `ConversationManager#purge` | "Delete Chat" button wipes the thread immediately |

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
| `app/agents/secure_chat_agent.rb` | Agent with PromptInjection + PII guardrails |
| `app/graphs/summarization_graph.rb` | Single-node graph with encrypted checkpoint |
| `app/controllers/messages_controller.rb` | Handles chat with TTL purge and user_id |
| `app/controllers/conversations_controller.rb` | New chat / delete chat (purge) |
| `app/controllers/summaries_controller.rb` | Triggers SummarizationGraph (Feature C) |
| `config/initializers/phronomy.rb` | LLM settings, encryptor, TTL constant |

## Multi-User Behaviour

Each browser session receives an independent `user_id` (UUID) and `thread_id`.
Open the app in a normal tab (User A) and a private window (User B) to verify
that sessions are fully isolated — neither user can see the other's messages.

## Running the Scenario Test

A headless-Chrome scenario test verifies all four features automatically:

```bash
bundle exec ruby scenario/multi_user_test.rb
```

Screenshots are saved to `scenario/evidence/`.
