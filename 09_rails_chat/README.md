# 09 Rails Chat App

A Rails web application demonstrating phronomy's `ConversationManager` for
persistent, per-session chat history backed by ActiveRecord.

## Purpose

Show how to integrate phronomy memory into a Rails controller so that each
browser session maintains its own conversation thread, with history stored
in a `phronomy_messages` table.

## Phronomy Features

| Feature | Usage |
|---------|-------|
| `acts_as_phronomy_message` | ActiveRecord model mixin for message storage |
| `PhronomyMessage.phronomy_memory` | Builds a `ConversationManager` from the model |
| `Agent::Base config: { memory:, thread_id: }` | Injects memory into the agent |

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
| `app/agents/chat_agent.rb` | Phronomy agent with LLM |
| `app/controllers/messages_controller.rb` | Passes memory and thread_id to the agent |
| `app/views/conversations/index.html.erb` | Chat UI |
| `config/initializers/phronomy.rb` | LLM configuration |

* Deployment instructions

* ...
