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
`phronomy-examples`. SQLite3 is deliberately used before PostgreSQL so the full
portable Persistence contract can be exercised without provisioning a database
server.

## Scope

The example implements:

- `contents`
- `agents`
- `journals`
- `executions`
- `workflow_states`
- `handoff_states`
- `teams`
- `team_executions`
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
  Phronomy::Persistence.new(backend: PhronomyExamples::Persistence::ActiveRecordSQLite.new(
    connection_pool: ActiveRecord::Base.connection_pool
  ))
```

Example `09_rails_chat` uses exactly this constructor with its Rails primary
connection pool.

## SQLite transaction model

ActiveRecord 8.1's SQLite adapter uses SQLite `IMMEDIATE` transactions by
default. That gives a write transaction its writer reservation at transaction
start instead of relying on a later deferred read-to-write upgrade.

This reference backend still treats SQLite lock/busy failures as storage
failures. It does **not** translate `SQLITE_BUSY` into
`Phronomy::Storage::ConflictError`.

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

- duplicate `execution_id` → `Storage::ConflictError`
- another active execution for the Agent → `Phronomy::AgentBusyError`

## Durable representation

Except for content bytes, the raw backend stores opaque
`Phronomy::Storage::DurableRecord` envelopes. Phronomy owns domain encoding,
decoding, and compatibility validation. Identity, revision, journal position,
and active-execution metadata arrive as separate repository arguments. The
backend's Codec serializes the envelope and does not inspect domain payloads.
No Marshal or arbitrary Ruby-object serializer is used.

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

- all nine authoritative Persistence shared examples
- transaction/watermark tests
- two-connection/thread competition for Agent CAS
- Execution CAS
- Journal append
- Workflow CAS
- active Execution admission
- transactional `assert_idle!` + admission serialization
- fresh-pool durability/reload for all eight durable repositories
- unsupported Workflow serialization

SQLite is a single-writer database. Therefore these concurrency tests prove
that the **observable conflict result** is correct across distinct Ruby threads
and ActiveRecord connections. They do not prove PostgreSQL-style true
multi-writer or row-level-lock behavior.

Those server-database concerns are covered separately by
`31_postgresql_persistence`.

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

The demonstration writes durable state, closes the ActiveRecord pool, creates a
fresh pool, and reloads the stored values.

It does not require an LLM API key.

## Relationship to the other Persistence examples

```text
29_unified_persistence
    architecture / ownership semantics
        ↓
30_sqlite_persistence
    portable external backend / SQLite contract and durability
        ↓
09_rails_chat
    Rails consumer / real Agent → LLM → SQLite Persistence
        ↓
31_postgresql_persistence
    true multi-writer / row-level locking / server DB failures
```

`29_unified_persistence` remains the compact architecture example and uses
`Persistence.in_memory` intentionally.

## Rails integration

Example `09_rails_chat` is the Phase A consumer integration for this backend.
It deliberately reuses the implementation from this example instead of copying
repository classes into the Rails application.

The Rails initializer injects:

```ruby
Phronomy::Persistence.new(backend: PhronomyExamples::Persistence::ActiveRecordSQLite.new(
  connection_pool: ActiveRecord::Base.connection_pool
))
```

and Rails owns schema provisioning through its migration. The controllers keep
using Phronomy's normal public Agent lifecycle:

```text
ChatAgent.create
ChatAgent.load
ChatAgent#invoke
```

so Persistence remains below the Agent boundary rather than leaking into
Runtime or application execution logic.

The repository Playwright smoke test sends a real LLM turn through example 09
and reloads the page to verify that the durable transcript is available through
`ChatAgent.load`.

## PostgreSQL Phase B companion

`31_postgresql_persistence` implements a second concrete ActiveRecord backend
against PostgreSQL. It runs the same authoritative contract and adds
PostgreSQL-specific validation for:

- true concurrent independent writers
- row-level lock behavior
- same-Agent lock contention
- deadlock / lock-order behavior
- terminated database-session failure classification

The SQLite and PostgreSQL implementations remain intentionally separate in this
phase. Only after both concrete backends have been exercised should common
implementation code be considered for extraction, and only when extraction does
not hide transaction or locking semantics.

## Coordination repositories and upgrades

`handoff_states` uses a main-Agent anchor and compare-and-swap revisions.
`teams` stores Team roots. `team_executions` admits one active run per Team,
retains terminal results, and rejects reactivation of a terminal run. Both Agent
and Team execution repositories support owner-scoped cursor pagination.
All eight repositories participate in the same transaction and transaction view.
The backend stores opaque DurableRecord envelopes and indexes only the metadata
passed separately by Phronomy; it does not reconstruct execution semantics.

`SQLiteSchema.apply!` creates the three additional
coordination tables when opening an older database. Existing records are retained.
Example 09 uses its dedicated Rails migration instead.

Shared SQL regressions cover concurrent initial saves/CAS/admission, terminal
protection, pagination, and reconnecting all three coordination repositories.
Phronomy's authoritative contract verifies rollback across all eight repositories.

## Storage constraint notification migration

This backend requires a core revision providing
`Phronomy::Storage::ActiveExecutionConflictError` (ADR-043). For source checkout
verification, set `PHRONOMY_PATH` to that updated core before resolving the bundle
and running the specs. Apply the core update before this backend update.

Raw execution repository calls now raise that Storage-owned `ConflictError`
subtype for an existing nonterminal execution. Domain calls through
`Phronomy::Persistence` continue to raise `Phronomy::AgentBusyError`, with the
storage exception retained as `cause`. Direct raw callers must update their
rescue; duplicate IDs and revision conflicts remain ordinary `ConflictError`.
SQL, indexes, schemas, lock/transaction boundaries and record formats are unchanged.
The shared `a Persistence backend` suite checks both raw notification and rollback;
existing domain, transaction, concurrency and failure specs still apply.

## Refactor 34 transaction migration

Explicit nested `backend.transaction` or `persistence.transaction` calls on the
same backend and synchronous execution context now use savepoints on the same
connection. A failed inner block rolls back only its changes and re-raises the
same exception. Catch outside that inner block if the outer scope should continue.
A successful inner block is still rolled back if the outer block fails.

Previously ActiveRecord joined nested scopes, so catching the inner exception
could leave its writes pending in the outer transaction. Code depending on those
writes must change. `ActiveRecord::Rollback` also propagates from this API after
rollback; it is no longer silently consumed as it is by ActiveRecord itself.

Journal append validates and serializes the complete input batch before writing.
This prevents an invalid later record from leaving partial rows and an unchanged
head. It does not make arbitrary database failures safe to catch and ignore in
the same scope. Let database errors escape, or establish an explicit inner
transaction before the operation and catch outside it.

Schemas, durable record formats, public method signatures, parent-row lock order
and transaction-bound connection access are unchanged. Use normal block completion
or exceptions; non-local exits (`return`, `break`, `throw`) are not portable commit
controls. Run the matching core contract suite with this adapter.
