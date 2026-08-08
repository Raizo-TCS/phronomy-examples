# 09 Rails Chat App

A Rails web application demonstrating phronomy stateful `Agent::Base` for
persistent, per-session conversation history stored in `Persistence::InMemory`.

## Purpose

Show how to integrate phronomy stateful Agent into a Rails controller so that
each browser session maintains its own conversation using `Agent.create` and `Agent.load`.

## Phronomy Features

| Feature | Class / API | Usage |
|---------|-------------|-------|
| Stateful agent | `Agent::Base` + `agent_definition` | `ChatAgent` retains conversation history across turns |
| Agent lifecycle | `Agent.create` / `Agent.load` | `ConversationsController` creates; `MessagesController` loads by `agent_id` |
| Shared persistence | `Persistence::InMemory` | `PhronomyStore.persistence` shared across all sessions (process-local) |
| Transcript read-back | `agent.transcript` | `ConversationsController#index` renders past messages from the journal |

## How to Run

```bash
cd 09_rails_chat
bundle install
bundle exec rails db:create db:migrate
bundle exec rails server
```

Then open `http://localhost:3000` in a browser.

## Key Files

| File | Description |
|------|-------------|
| `app/agents/chat_agent.rb` | `ChatAgent < Agent::Base` with `agent_definition` |
| `app/controllers/conversations_controller.rb` | `Agent.create` (new chat) + `agent.transcript` (message display) |
| `app/controllers/messages_controller.rb` | `Agent.load` + `agent.invoke(content)` |
| `config/initializers/phronomy_store.rb` | `PhronomyStore` module wrapping `Persistence::InMemory` |
| `app/views/conversations/index.html.erb` | Chat UI (reads `@agent_id`) |
