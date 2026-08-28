# 29 — Unified Persistence and durable ownership

This is the compact entry point for the current Unified Persistence architecture.
The same `Phronomy::Persistence` backend stores Agent durable state and Workflow
`workflow_states`, while live mutable ownership remains a separate Runtime
concern.

## Agent ownership

`UnifiedPersistenceAgent.create` creates one durable logical Agent. In the same
Runtime, `UnifiedPersistenceAgent.load(agent_id, persistence: ...)` resolves the
existing live owner instead of constructing another mutable Agent object for the
same `agent_id`.

The example therefore demonstrates both boundaries explicitly:

- `persistence.agents.load(agent_id)` reads the committed durable `AgentRoot`;
- `UnifiedPersistenceAgent.load(...)` resolves/hydrates the logical Agent owner,
  but returns the existing owner when one is already live in the process.

## Workflow identity

`workflow_instance_id` is the durable logical Workflow identity. It is supplied
through:

```ruby
workflow.invoke(input, config: {workflow_instance_id: "approval-42"})
```

and is available from `WorkflowContext#workflow_instance_id`. Runtime-internal
`fsm_session_id` is a separate execution detail and is not application identity.

## Limits

This example does not claim distributed execution exclusion, cross-process
ownership coordination, or exactly-once external side effects. Optimistic
revisions detect stale durable commits; they are not a distributed lease or
fencing protocol.

## Run

From the repository root:

```bash
./scripts/update_phronomy.sh
bundle exec ruby 29_unified_persistence/run.rb
```
