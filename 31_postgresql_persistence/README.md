# 31 — PostgreSQL Persistence reference backend

This example is Phase B of the database-backed `Phronomy::Persistence` reference
implementation.

```text
29_unified_persistence
    architecture / ownership semantics
        ↓
30_sqlite_persistence
    portable external backend contract / SQLite durability
        ↓
09_rails_chat
    real Agent → LLM → SQLite consumer path
        ↓
31_postgresql_persistence
    server DB / true multi-writer / row-level locking
```

It deliberately remains a **separate concrete backend** from
`30_sqlite_persistence`. No generic ActiveRecord persistence base class is
introduced yet. The two implementations should only be commonized later if the
actual duplication can be extracted without hiding transaction or locking
semantics.

## What Phase B proves

The backend implements the same public Persistence SPI and the same five durable
repositories as the SQLite reference:

- `contents`
- `agents`
- `journals`
- `executions`
- `workflow_states`
- `transaction`
- `assert_agent_watermark!`

It advertises the same required capabilities:

```ruby
{
  atomic_all: true,
  atomic_admission: true,
  optimistic_revision: true
}
```

PostgreSQL adds validation that SQLite cannot provide:

- distinct connections can make progress on different Agent rows concurrently;
- same-row CAS writers block at the row and only one stale precondition wins;
- Agent execution admission is serialized per Agent without database-wide
  writer serialization;
- Journal and Execution operations share a stable per-Agent lock anchor;
- PostgreSQL deadlocks surface as storage/transaction failures and are not
  relabeled as optimistic conflicts;
- an actual terminated database session is not translated into
  `Persistence::ConflictError`.

## Locking model

The durable Agent row is the per-Agent serialization anchor.

Operations that must not race with Agent execution admission or the durable
Agent watermark acquire:

```sql
SELECT agent_id
FROM phronomy_agents
WHERE agent_id = ...
FOR UPDATE
```

before taking subordinate Journal or Execution locks.

The effective order is therefore:

```text
Agent row
  ↓
Journal head / Journal records
  or
Execution rows
```

This is important for two reasons:

1. `assert_agent_watermark!` can lock the Agent row, read the Agent revision and
   Journal head, and keep concurrent Agent/Journal mutations out until the
   surrounding transaction completes.
2. `executions.assert_idle!` and `executions.create_active` acquire the same
   Agent-row lock, so an idle check inside a transaction cannot race with
   admission.

Different Agents use different PostgreSQL rows and can therefore make progress
concurrently.

A caller that deliberately locks **multiple different Agents in one application
transaction** is responsible for acquiring those Agents in a stable order. The
SPI does not define distributed or multi-Agent lock ordering. The test suite
intentionally creates an opposite-order deadlock and verifies that PostgreSQL's
deadlock error remains a storage transaction error rather than being converted
to `ConflictError`.

## Why PostgreSQL unique violations are mostly avoided

PostgreSQL marks a transaction unusable after a database statement error such
as a unique-constraint violation until the transaction is rolled back.

Therefore this backend does not depend on rescuing a unique violation and then
continuing to query inside the same transaction. Where a logical duplicate is
an expected contract outcome it uses PostgreSQL primitives such as:

```sql
INSERT ... ON CONFLICT DO NOTHING RETURNING ...
```

and then raises the appropriate portable Phronomy error without poisoning the
transaction first.

The partial unique index on active Executions remains a hard database invariant
in addition to the Agent-row admission lock.

## Durable representation

The backend implements Phronomy's record-oriented Persistence SPI. Except for the ContentStore, raw backend repositories persist opaque `Phronomy::Persistence::DurableRecord` envelopes. `agent_id`, revisions, Journal record IDs/positions, Execution admission metadata, and Workflow revisions are supplied separately as backend arguments; backend code does not decode Phronomy domain objects or inspect `DurableRecord#payload` to rediscover index semantics.

Content bytes are stored as PostgreSQL `bytea`. The reference implementation
uses PostgreSQL `decode(..., 'hex')` and `encode(..., 'hex')` so arbitrary binary
content does not depend on Ruby string quoting behavior.

No `Marshal`, Runtime object serialization, private Phronomy API, or backend-owned Agent/Workflow domain codec is used.

## Start PostgreSQL locally

A PostgreSQL 17 server is sufficient. For example:

```bash
docker run --rm --name phronomy-postgres \
  -e POSTGRES_USER=postgres \
  -e POSTGRES_PASSWORD=postgres \
  -e POSTGRES_DB=phronomy_persistence_test \
  -p 5432:5432 \
  postgres:17
```

In another shell:

```bash
export PHRONOMY_POSTGRES_URL='postgresql://postgres:postgres@127.0.0.1:5432/phronomy_persistence_test'
```

Then install and run:

```bash
cd 31_postgresql_persistence
bundle install
bundle exec rspec
```

The default URL, when the environment variable is omitted, is the same localhost
URL shown above.

## Test coverage

The RSpec suite runs all six authoritative shared examples from Phronomy:

```ruby
require "phronomy/testing/persistence_contract"
```

and adds PostgreSQL-specific tests for:

- cross-repository transaction commit/rollback;
- durable Agent watermark;
- distinct-Agent true multi-writer progress;
- same-Agent row lock contention;
- Agent CAS;
- Execution CAS;
- Journal expected-position CAS;
- Workflow initial CAS;
- atomic Execution admission;
- common Journal/Execution Agent-row lock order;
- deliberate opposite multi-Agent deadlock classification;
- fresh-pool durability for all five durable repositories;
- terminated-session and unavailable-endpoint storage failure classification.

The database-specific tests use separate ActiveRecord connections and
PostgreSQL's `pg_blocking_pids()` to verify real server-side lock waits instead
of inferring contention from sleeps.

## Durable reload demo

```bash
bundle exec ruby run.rb
```

The demo writes all five durable repository types, disconnects the first
ActiveRecord pool, constructs a fresh pool against the same PostgreSQL database,
and reloads the stored values.

It does not require an LLM key.

## Repository verification

The ordinary repository verifier remains usable without a PostgreSQL server:

```bash
./scripts/verify_examples.sh
```

Use the dedicated Phase B verifier when PostgreSQL is available:

```bash
export PHRONOMY_POSTGRES_URL='postgresql://postgres:postgres@127.0.0.1:5432/phronomy_persistence_test'
./scripts/verify_postgresql_persistence.sh
```

GitHub Actions provisions PostgreSQL 17 as a service container and runs the
PostgreSQL suite on Ruby 3.2, 3.3, and 3.4.

## Error classification

Portable contract failures are translated only when their meaning is known:

| Condition | Result |
|---|---|
| missing durable record | `Persistence::NotFoundError` |
| stale revision / Journal position | `Persistence::ConflictError` |
| duplicate logical identity | `Persistence::ConflictError` |
| active Execution already exists for Agent | `Phronomy::AgentBusyError` |
| unsupported Workflow value | `Persistence::SerializationError` |
| connection loss / server failure | database/storage exception |
| PostgreSQL deadlock | `ActiveRecord::Deadlocked` |

Connection loss, server unavailability, deadlocks, and indeterminate commit
outcomes are deliberately **not** converted into optimistic conflicts.

## Relationship to future commonization

This phase intentionally keeps:

```text
ActiveRecordSQLite
ActiveRecordPostgreSQL
```

independent.

After both reference implementations have been exercised in CI, common code can
be reviewed for extraction. Codec duplication may be a reasonable candidate.
Transaction setup, lock strategy, CAS SQL, admission, and backend-specific error
handling should remain concrete unless extraction makes their semantics clearer,
not less visible.
