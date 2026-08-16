# 09 Rails Chat App

A Rails web application demonstrating a stateful `Phronomy::Agent::Base` whose
durable Agent state is stored in the Rails primary SQLite database through the
ActiveRecord-backed Persistence reference implementation from
`30_sqlite_persistence`.

## Purpose

Show the consumer side of the Persistence SPI after the standalone backend has
already passed the authoritative contract:

```text
browser
  ↓
Rails controller
  ↓
ChatAgent.create / ChatAgent.load
  ↓
ChatAgent#invoke
  ↓
Phronomy Agent lifecycle
  ↓
PhronomyExamples::Persistence::ActiveRecordSQLite
  ↓
ActiveRecord::Base.connection_pool
  ↓
Rails primary SQLite database
```

Each browser session keeps its logical `agent_id` in the Rails session cookie.
The Agent root, Journal, content, and durable Execution records live in SQLite,
so they are not tied to the lifetime of one Rails process.

## Phronomy Features

| Feature | Class / API | Usage |
|---------|-------------|-------|
| Stateful Agent | `Agent::Base` + `agent_definition` | `ChatAgent` retains Journal-backed conversation state across turns |
| Agent lifecycle | `Agent.create` / `Agent.load` | `ConversationsController` creates; subsequent requests load by durable `agent_id` |
| External durable Persistence | `PhronomyExamples::Persistence::ActiveRecordSQLite` | `PhronomyStore.persistence` injects the Rails primary connection pool |
| LLM invocation | `agent.invoke(content)` | `MessagesController` runs the normal Agent → LLM execution path |
| Transcript read-back | `agent.transcript` | `ConversationsController#index` reloads the logical transcript from durable Journal state |

There is intentionally no application-level ActiveRecord model for Phronomy
Agent state. The Persistence backend owns its `phronomy_*` storage tables and
the Agent Journal remains the canonical conversation state.

The backend implementation is **not copied into this Rails application**.
Example 09 loads the concrete implementation from sibling example
`30_sqlite_persistence` and injects `ActiveRecord::Base.connection_pool`.
This keeps one authoritative backend implementation while demonstrating how a
Rails consumer supplies its own database connection pool.

## Database schema

Run the Rails migration before starting the application:

```bash
bundle exec rails db:create db:migrate
```

`db/migrate/20260816180000_create_phronomy_persistence_tables.rb` provisions
the durable tables required by the SQLite reference backend:

```text
phronomy_contents
phronomy_agents
phronomy_journal_heads
phronomy_journal_records
phronomy_executions
phronomy_workflow_states
```

The checked-in `db/schema.rb` now reflects exactly those current Persistence
tables. An older development database may still physically contain legacy
`phronomy_messages` / `phronomy_checkpoints` tables from an earlier version of
this example. The current application does not read or write those tables and
this change deliberately does not add a destructive migration merely to remove
unused historical tables.

## LLM configuration

The application accepts the same environment variables used by the repository
verification script:

```bash
export PHRONOMY_MODEL="openai/gpt-oss-20b"
export PHRONOMY_BASE_URL="http://192.168.122.1:1234/v1"
export PHRONOMY_API_KEY="lm-studio"
export PHRONOMY_OUTPUT_RESERVE="4096"
```

`PHRONOMY_OUTPUT_RESERVE` is the fallback output-token reserve used when the
selected model does not publish a usable `max_output_tokens` value through the
model registry. Keep it positive and below the selected model's context window.

The values have local-development defaults, so an OpenAI-compatible LM Studio
endpoint at the default address works without editing source files.

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

Create a new chat and send a message. `MessagesController` loads the durable
Agent and calls `agent.invoke`, so the actual LLM turn is committed through the
SQLite Persistence backend. Reloading the page loads the same Agent and
transcript from the database.

With the same SQLite database and Rails session cookie, a later Rails process
can load the same logical Agent by `agent_id`; Runtime objects themselves are
not persisted or rehydrated.

## Verification

The repository Playwright smoke test for example 09 performs the consumer
end-to-end path:

1. create a new durable Agent;
2. send a real LLM message through the browser UI;
3. wait for the assistant response;
4. reload the page;
5. verify that the same user message and assistant response are rendered from
   the reloaded Agent transcript.

The standalone backend's transaction, concurrency, codec, and fresh-pool
durability guarantees remain tested in `30_sqlite_persistence`.

## Key Files

| File | Description |
|------|-------------|
| `app/agents/chat_agent.rb` | `ChatAgent < Agent::Base` with durable definition identity |
| `app/controllers/conversations_controller.rb` | `Agent.create` / `Agent.load` + transcript rendering |
| `app/controllers/messages_controller.rb` | `Agent.load` + real `agent.invoke(content)` |
| `config/initializers/phronomy_store.rb` | Injects Rails primary connection pool into example 30's backend |
| `db/migrate/20260816180000_create_phronomy_persistence_tables.rb` | Rails-owned provisioning for the Persistence tables |
| `../30_sqlite_persistence/lib/active_record_sqlite_persistence.rb` | Authoritative concrete SQLite backend implementation |
| `app/views/conversations/index.html.erb` | Chat UI |
