# r8 unit 3 examples migration

Use these examples with the matching core candidate based on `a82974a7`.
The examples base is `70b7244c`. Both repositories should use branch
`refactor/r8-unit3`; the workflows already check out the matching core branch.
Set `PHRONOMY_PATH` to the updated core worktree before `bundle install`.
The API preflight rejects the previous shared Persistence facade.

```ruby
stores = Phronomy::PersistenceComposition.in_memory
# Or: PersistenceComposition.build(backend: sql_backend)
Phronomy.configure do |config|
  config.agent_store = stores.agent
  config.team_store = stores.team
  config.workflow_store = stores.workflow
end
```

Pass only the corresponding store in `persistence:` to Agent, Team, or Workflow.
Agent-only construction can use `PersistenceComposition.agent`. Raw SQL drivers,
physical schema, locks and Storage SPI 2 are unchanged. The backend contract suite
now uses a `stores` fixture and explicitly participates across domain ports in a
shared scope. It still checks cross-domain rollback, savepoints and admission.

`stores.agent.result(id)` / `.runs(agent_id)` and `stores.team.result(id)` /
`.runs(team_id)` replace shared-facade result and listing APIs. There are no legacy
aliases. Team now balances by its own assignment count; custom schedulers use
`assignment_count` rather than an Agent journal-derived `transcript_size`.

Validation:

- Run `scripts/verify_offline.sh` for API stubs, syntax, SQLite contracts and reload.
- Run the real PostgreSQL suite in `31_postgresql_persistence` with
  `PHRONOMY_POSTGRES_URL`; this includes the three parent/child race-order tests.
- Core and examples must both pass branch/PR CI before merge. The unit 2
  PostgreSQL CI result does not validate this candidate.

This migration does not implement durable Workflow child execution, distributed
transactions, external exactly-once effects, or complete the remaining
subagent/Handoff ownership redesign.
