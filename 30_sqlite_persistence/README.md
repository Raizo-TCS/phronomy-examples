# 30 — SQLite Persistence reference backend

This example implements the public `Phronomy::Persistence` Backend SPI with a
real durable database:

```text
Phronomy public Persistence SPI
        ↓
ActiveRecord connection pool / transactions
        ↓
SQLite3 file
```

It is the first database-backed reference implementation in
`phronomy-examples`. It deliberately uses SQLite3 before PostgreSQL so the full
portable Persistence contract can be exercised without provisioning a database
server.

## Scope

The example implements:

- `contents`
- `agents`
- `journals`
- `executions`
- `workflow_states`
- `transaction`
- `assert_agent_watermark!`

and advertises all required capabilities:

```ruby
{
  atomic_all: true,
  atomic_admission: true,
  optimistic_revision: true
}
```

The backend depends only on Phronomy's public Persistence SPI and public durable
domain codecs. It does not access Runtime, EventLoop, FSMSession, live
Activation objects, or other execution internals.

## Why ActiveRecord but not Rails?

ActiveRecord is used as the database access layer:

- connection pooling
- transaction lifecycle
- SQLite adapter
- schema operations

The backend itself does not require Rails and does not refer to
`ApplicationRecord` or `Rails.application`.

A caller injects a connection pool:

```ruby
backend =
  PhronomyExamples::Persistence::ActiveRecordSQLite.new(
    connection_pool: ActiveRecord::Base.connection_pool
  )
```

That same constructor can later be used by a Rails application.

## SQLite transaction model

ActiveRecord 8.1's SQLite adapter uses SQLite `IMMEDIATE` transactions by
default. That gives a write transaction its writer reservation at transaction
start instead of relying on a later deferred read-to-write upgrade.

This reference backend still treats SQLite lock/busy failures as storage
failures. It does **not** translate `SQLITE_BUSY` into
`Phronomy::Persistence::ConflictError`.

Optimistic conflicts are only the portable Phronomy precondition failures such
as stale revisions and stale Journal positions.

## Atomic Agent admission

The repository stores a derived `active` column from the public
`AgentExecution#active?` result. The schema creates a partial unique index on
that flag, so one Agent cannot have two durable active executions.

This avoids coupling the database schema to Phronomy's internal list or layout
of status constants.

The repository also performs the normal semantic checks so it can translate
conflicts into the portable errors:

- duplicate `execution_id` → `Persistence::ConflictError`
- another active execution for the Agent → `Phronomy::AgentBusyError`

## Durable representation

Phronomy domain records use their public codecs:

- `AgentRoot#to_h` / `.from_h`
- `JournalRecord#to_h` / `.from_h`
- `AgentExecution#to_h` / `.from_h`

Workflow state uses a deliberately narrow JSON-compatible domain:

- `nil`
- String
- Integer
- finite Float
- `true` / `false`
- recursive Array
- recursive Hash with String/Symbol keys

Unsupported values raise `Phronomy::Persistence::SerializationError`.

No `Marshal` or arbitrary Ruby-object serializer is used.

## Install

From the repository root:

```bash
./scripts/update_phronomy.sh
```

The update script includes this example's independent bundle.

Or install this bundle directly:

```bash
cd 30_sqlite_persistence
bundle install
```

## Contract and integration tests

The contract source is not copied into this repository. The spec loads the same
contract shipped by Phronomy:

```ruby
require "phronomy/testing/persistence_contract"
```

Run:

```bash
cd 30_sqlite_persistence
bundle exec rspec
```

The suite includes:

- all six authoritative Persistence shared examples
- transaction/watermark tests
- two-connection/thread competition for Agent CAS
- Execution CAS
- Journal append
- Workflow CAS
- active Execution admission
- transactional `assert_idle!` + admission serialization
- fresh-pool durability/reload
- unsupported Workflow serialization

SQLite is a single-writer database. Therefore these concurrency tests prove
that the **observable conflict result** is correct across distinct Ruby threads
and ActiveRecord connections. They do not prove PostgreSQL-style true
multi-writer or row-level-lock behavior.

That additional validation belongs to the later PostgreSQL phase.

## Run the durable-state demonstration

```bash
cd 30_sqlite_persistence
bundle exec ruby run.rb
```

By default the database is:

```text
30_sqlite_persistence/storage/phronomy.sqlite3
```

Override it with:

```bash
PHRONOMY_SQLITE_DB=/path/to/phronomy.sqlite3 bundle exec ruby run.rb
```

The demonstration writes Agent, Journal, Content, and Workflow state, closes the
ActiveRecord pool, creates a fresh pool, and reloads the durable state.

It does not require an LLM API key.

## Relationship to example 29

`29_unified_persistence` remains the compact architecture example and uses
`Persistence::InMemory` intentionally.

```text
29_unified_persistence
    architecture / ownership semantics
        ↓
30_sqlite_persistence
    external durable backend / contract / SQLite concurrency results
```

This example does not replace example 29.

## Rails integration

The existing Rails examples already use ActiveRecord and SQLite3, so this
backend is intentionally constructed to accept an injected ActiveRecord
connection pool.

However, the Rails examples are **not modified in this phase**. First this
standalone backend must pass its authoritative contract and concurrency suite.
After that is green, a Rails example can consume the same backend without
copying its implementation.

## PostgreSQL next

SQLite validates the portable Persistence contract, but not:

- true concurrent independent writers
- row-level lock behavior
- PostgreSQL deadlocks / lock ordering
- server/network failure behavior

The next phase adds a separate PostgreSQL reference backend and runs the same
authoritative contract there, followed by PostgreSQL-specific concurrency tests.

Only after both concrete backends exist should common implementation code be
considered for extraction.
