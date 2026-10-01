# 17 Multi-Agent Handoff

This version requires the matching r8 unit 4 core with
`Phronomy::MultiAgent::HandoffRunner`; set `PHRONOMY_PATH` to that checkout.
The released 0.26.0 core still uses the previous Runner namespace.

This example uses `Phronomy::MultiAgent::HandoffRunner` and explicit
`Phronomy::MultiAgent::Handoff` edges. All Agents in a conversation share one
composition: Agents receive `stores.agent`, and the runner receives
`stores.multi_agent`. Phronomy supplies the corresponding Handoff tools.

| Input | Initial Agent | Intended specialist |
| --- | --- | --- |
| Billing question | TriageAgent | BillingAgent |
| Technical question | TriageAgent | TechSupportAgent |
| Business hours | TriageAgent | TriageAgent answers directly |

Each CLI scenario creates an independent conversation with `HandoffDemo.build_runner`.
Reusing one runner deliberately keeps its active specialist for later turns;
constructing another runner around the same saved main Agent does not reset
that routing. Restarting an actual conversation requires the same durable
Persistence backend, compatible Agent definitions, and its original Agent IDs
and Handoff edges. The CLI uses InMemory, so it does not retain data after the
process exits.

`result[:agent]` identifies the final answering Agent. Handoff transfers active
responsibility; it does not create a parallel worker pool.

```bash
bundle exec ruby 17_multi_agent_handoff/run.rb
```

The offline gate executes all three scenarios with protocol stubs and separately
checks specialist continuity. The SQLite suite also checks continuity after
reconnecting the database and creating a fresh Runtime.
