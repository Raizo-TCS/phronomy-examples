# 30 — SQLite Persistence reference backend

This example composes `Phronomy::Persistence` over neutral Storage SPI 2 with a
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

The composed Persistence facade exposes:

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

The physical driver depends on the neutral Storage SPI. Domain codecs belong to core repositories. It does not access Runtime, EventLoop, FSMSession, live
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

## Refactor 35: neutral Storage SPI 2

Apply the matching core update and set PHRONOMY_PATH before resolving dependencies.
The core requires spi_version 2 and neutral atomic_resources, record_cas,
stream_cas, conditional_unique, guarded_checks and nested_savepoints capabilities.
Public Persistence retains its existing eight domain repositories and three
capability names. Raw Backend exposes a View with Records, Streams and Blobs.

The driver is shared in ../shared/storage. Domain resources and existing table
names are wired separately in ../shared/persistence_storage_mapping.rb. The
physical driver has no domain resource-ID switch, domain codec, active-state
interpretation, content digest or Agent watermark API. Table/index definitions,
record type/version/payload and content bytes are unchanged.

UniqueConstraintError carries a resource ID and named constraint. Domain wrappers
translate only their active-owner constraint to AgentBusyError. Parent guards,
CAS and partial unique indexes remain atomic. NoRows and revision/head conditions
are checked after locking their stable anchors. Required missing parents raise
NotFoundError consistently across drivers.

Nested transactions use same-connection savepoints. Catch errors outside the
inner scope if the outer transaction should continue. A failed physical scope
rejects further operations and successful commit; do not catch and ignore an
operation error inside it. ActiveRecord::Rollback propagates. Non-local return,
break and throw cause TransactionError and rollback. Bound views/handles expire
at scope exit and reject cross-thread use; cached root handles join the current
transaction. Complete stream batches are validated before writes.

Run the shipped neutral/domain contracts and the database-specific tests against
the matching candidate core. S2a results do not verify the new SPI; live PostgreSQL
locking, deadlock, connection-failure and fresh-pool tests remain a release gate.
