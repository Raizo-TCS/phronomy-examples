# 09 Rails Chat App

A Rails web application demonstrating a stateful `Phronomy::Agent::Base` with
per-browser-session conversation history stored in `Persistence::InMemory`.

## Purpose

Show how to integrate a stateful Phronomy Agent into Rails so that each browser
session maintains its own logical Agent using `Agent.create` and `Agent.load`.

## Phronomy Features

| Feature | Class / API | Usage |
|---------|-------------|-------|
| Stateful Agent | `Agent::Base` + `agent_definition` | `ChatAgent` retains Journal-backed conversation state across turns |
| Agent lifecycle | `Agent.create` / `Agent.load` | `ConversationsController` creates; `MessagesController` loads by `agent_id` |
| Shared Persistence | `Persistence::InMemory` | `PhronomyStore.persistence` shared across all sessions in this process |
| Transcript read-back | `agent.transcript` | `ConversationsController#index` renders the logical transcript from the Journal |

This demo intentionally has **no Rails ActiveRecord checkpoint/message model for
Phronomy state**. The Agent Journal and Persistence backend are the canonical
Phronomy state. `Persistence::InMemory` keeps the example self-contained, so
restarting the Rails process clears its Agent history.

For production durability, replace the in-memory backend with a durable
`Phronomy::Persistence` implementation. Application domain records may of course
still use ActiveRecord independently.

## How to Run

From the repository root, update all bundles to the configured Phronomy source:

```bash
./scripts/update_phronomy.sh
```

Then:

```bash
cd 09_rails_chat
bundle exec rails db:create db:migrate
bundle exec rails zeitwerk:check
bundle exec rails server
```

Open `http://localhost:3000`.

## Key Files

| File | Description |
|------|-------------|
| `app/agents/chat_agent.rb` | `ChatAgent < Agent::Base` with `agent_definition` |
| `app/controllers/conversations_controller.rb` | `Agent.create` + `agent.transcript` |
| `app/controllers/messages_controller.rb` | `Agent.load` + `agent.invoke(content)` |
| `config/initializers/phronomy_store.rb` | Shared `Persistence::InMemory` instance |
| `app/views/conversations/index.html.erb` | Chat UI |
