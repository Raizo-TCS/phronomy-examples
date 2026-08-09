# 15 Rails Secure Chat App

A Rails application showing trust boundaries around a stateful Phronomy Agent.

## Phronomy features

| Feature | API | Role |
|---|---|---|
| Prompt-injection filter | `Phronomy::Filter::PromptInjectionFilter` | Blocks common instruction-override patterns before the LLM boundary |
| Application PII policy | `Phronomy::Filter::Base` | Demonstrates custom input/output Filters |
| Stateful Agent | `Agent.create` / `Agent.load` | Gives each browser session an independent Agent identity |
| Canonical transcript | `agent.transcript` | Reads Journal-backed conversation state |
| Caller metadata | `config: { user_id:, session_id: }` | Propagates application identity metadata into the invocation |
| Async summarization | `invoke_async` + `Workflow#signal` | Keeps Workflow state transitions event-driven |
| Logical context clear | `agent.clear_transcript!` | Advances transcript generation without deleting Journal history |

The security boundary is intentionally expressed through the current Filter API.
The removed `Phronomy::Guardrail::*` hierarchy is not used.

`PromptInjectionFilter` is defense-in-depth, not an authorization boundary.
Application authorization and data-access checks must still be enforced outside
the model.

## Run

From the repository root, first update the common Phronomy dependency:

```bash
./scripts/update_phronomy.sh
```

Then:

```bash
cd 15_rails_secure_chat
bundle exec rails db:create db:migrate
bundle exec rails server -p 3002
```

Open `http://localhost:3002`.

## Key files

| File | Responsibility |
|---|---|
| `app/agents/secure_chat_agent.rb` | Built-in prompt-injection Filter + application PII Filters |
| `app/graphs/summarization_graph.rb` | Async Workflow summarization via `Workflow#signal` |
| `app/controllers/conversations_controller.rb` | Agent lifecycle and transcript access |
| `app/controllers/messages_controller.rb` | Agent invocation, TTL clearing and `FilterBlockError` handling |
| `config/initializers/phronomy.rb` | LLM and persistence setup |

## Container build

The shared `Gemfile.phronomy` lives at the repository root, so this proposal's
Dockerfile expects the repository root to be the Docker build context. The
Kamal `builder.context` setting is updated accordingly.
