# 21 — TeamCoordinator: durable stateful worker pool

A coordinator plans blog sections; two worker identities retain their own
conversation state across assignments. Work is assigned sequentially. For
bounded parallel execution, see `23_bounded_parallel`.

`agents.rb` declares the worker `agent_definition` and the Team's required
`team_definition id:, version:`. A long-lived application should choose a
stable `team_id` and a durable Persistence backend, create the Team once, then
load that identity and resume the saved `team_execution_id` after restart.
The CLI creates a new InMemory Team for each demonstration attempt.

The aggregate receives symbol-keyed assignments. Its return value is saved as
canonical JSON, so callers read string keys such as `result.fetch("sections")`.
Aggregation must be safe to repeat until its result is durably committed.
A completed Team result can be resumed without running the workers or aggregate
again.

`TeamCoordinator#stream` accepts a task-progress callback. Its event fields have
symbol keys, while `event[:error]` is canonical error data: read its `"message"`
key instead of calling an exception's `message` method. This callback is not a
durable notification mechanism.

```bash
bundle exec ruby 21_team_coordinator/run.rb
```

The offline gate executes this CLI and checks reading a terminal result after
Runtime restart. The SQLite suite also verifies the same behavior across a
database reconnection using this sample's actual Team definition.
