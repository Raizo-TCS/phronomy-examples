# r8 unit 2: Persistence participation for admission

Use this change together with the unit 2 revision of r8 unit 1 at core `16e6fcb2…`.
Set `PHRONOMY_PATH` to that checkout. API preflight checks `atomic` and the Agent admission operation.

Ordinary application usage of invoke, Team, and Handoff is unchanged. Core composes parent reservation validation and persistence participation for child admission.

- Add five shared SQLite/PostgreSQL tests: admission, cancellation before admission, rollback on Agent CAS failure, an outer savepoint, and cancellation of an admitted Handoff Target.
- Add three PostgreSQL concurrency tests: cancellation wins, admission wins, and admission commits after Handoff observes absence. Check actual lock waiting through `pg_blocking_pids`.
- Retain checkout of the same-named core branch in the workflow and add changes to the shared test file to the workflow trigger conditions. Push the core branch first and use the same branch name in examples.
- These database backends inherit Storage::Backend, so they use the shared implementation of the new `transaction_open?` operation.

For local verification against a real PostgreSQL instance, set `PHRONOMY_POSTGRES_URL` and run `scripts/verify_postgresql_persistence.sh`. Ordinary offline verification does not run PostgreSQL. Integrate core into main before examples.
