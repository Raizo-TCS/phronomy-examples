# 10 — Stateful Agent Context: Journal → Policy → Manifest

This is the primary example for Phronomy's state/context architecture.

A Phronomy Agent does **not** treat the provider's mutable message array as the
canonical state. Conceptually, each invocation follows:

```text
Agent Journal
    ↓
Context candidates
    ↓
Context Policy + token budget
    ↓
LLMInputManifest
    ↓
provider-specific materialization
```

## What the example demonstrates

- `Agent.create` creates a persistent logical Agent.
- imported conversation history is recorded as Agent context.
- `knowledge:` and `add_knowledge` create persistent Knowledge candidates.
- `#transcript` is the current logical transcript projection.
- a deliberately constrained `context_window` exercises Context Policy under a
  bounded token budget while the canonical Agent state remains intact.
- `result[:messages]` is the current logical transcript materialization returned
  for application convenience; it is **not** the exact per-call
  `LLMInputManifest` or provider input.
- `Agent.load` reopens the same logical Agent from the Persistence backend.
- `clear_transcript!` and `clear_knowledge!` have independent logical lifetimes.
- `reset_context!` resets current context without treating provider messages as
  the source of truth.

The point is **not** merely "chat memory." The point is that persisted Agent
state and per-call model context are separate concepts.

The exact per-call `LLMInputManifest` remains framework-owned execution state;
`Agent#invoke` does not expose that manifest through `result[:messages]`. This
example therefore demonstrates the public state boundaries without pretending
that the returned logical transcript is the provider projection.

The reload section represents a later application/request boundary. Once the
same logical Agent is reloaded, the example stops mutating the original Ruby
Agent object. Applications should not treat two objects loaded for the same
`agent_id` as independent concurrent mutable owners.

Run:

```bash
bundle exec ruby 10_context_management/run.rb
```

The example uses `Persistence::InMemory` so it is self-contained. Production
applications should provide a durable Persistence backend when process restart
durability is required.
