# 29 — Unified Persistence and durable ownership

This example is the compact entry point for the Unified Persistence architecture
introduced for Phronomy 0.19.

The same `Phronomy::Persistence` backend supplies durable storage for both:

```text
Agent durable state ───────┐
                           ├─ Phronomy::Persistence
Workflow workflow_states ──┘
```

The example deliberately uses `Persistence::InMemory` so the mechanics are
visible without introducing a database adapter.

## What it demonstrates

### Global Persistence configuration

```ruby
persistence = Phronomy::Persistence::InMemory.new

Phronomy.configure do |config|
  config.persistence = persistence
end
```

Agent `new` / `create` and Workflows without an explicitly injected backend use
that global Persistence instance.

### Agent durable state

`UnifiedPersistenceAgent.create` creates a durable logical Agent, and
`Agent#invoke` produces an `execution_id`.

The live Agent object remains the current logical owner while it is active.
Persistence is the last committed durable representation; it is not a mutable
object registry that should be reloaded at every LLM boundary.

`Agent.load` is then shown explicitly with the same backend to represent a later
application boundary.

### Workflow durable state

The Workflow is invoked with an explicit `thread_id`. That makes the
`thread_id` the durable logical Workflow identity and causes snapshots to be
stored in:

```ruby
persistence.workflow_states
```

The example inspects the persisted revision and phase, then resumes the halted
Workflow with `Workflow#send_event`.

### Identity boundaries

The example prints these public identities:

- `agent_id` — durable logical Agent identity
- `execution_id` — one Agent execution identity
- `thread_id` — durable logical Workflow identity

Do not substitute one for another.

The Runtime also has an internal `fsm_session_id` for each Workflow execution,
but that is private implementation state and is intentionally not accessed by
this example. Application `session_id` is caller/tracing metadata and is also a
separate concept.

## Process-local and CAS limits

Workflow admission for a durable `thread_id` is Runtime/process-local. Separate
Ruby processes or service replicas can still begin work for the same
`thread_id`.

`workflow_states` optimistic revisions detect stale durable commits, but they
are **not** a distributed lease/fencing mechanism and do not undo external side
effects already performed by an execution that later loses a revision race.

This example therefore does not claim:

- distributed execution exclusion
- cross-process live Activation routing
- exactly-once external side effects
- durable Agent execution rehydration after process loss

Those are separate concerns from the unified Persistence abstraction.

## Run

From the repository root:

```bash
./scripts/update_phronomy.sh
bundle exec ruby 29_unified_persistence/run.rb
```

During pre-release validation `Gemfile.phronomy` tracks Phronomy `main`. After
Phronomy 0.19.0 is released, the repository dependency should be changed to
`phronomy ~> 0.19.0`.
