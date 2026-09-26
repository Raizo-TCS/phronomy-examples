# Domain Persistence failure contract

These examples accompany the core Persistence failure boundary refactor.
Use both candidates together via `PHRONOMY_PATH` until a containing core release
is available. This source change does not bump the RubyGems dependency or lockfiles.

Persistence repository callers now catch `Phronomy::Persistence::ConflictError`,
`NotFoundError`, `SerializationError` and `UnsupportedBackendError`.
Upper domain state contradictions can use `StateConflictError`, a ConflictError
subclass. Backend CAS errors retain their original Storage exception in `cause`.

SQLite/PostgreSQL driver and schema code still raise `Phronomy::Storage` errors.
Direct raw backend operations keep that contract. Domain conformance tests use
the upper contract; raw neutral-resource tests keep the lower one. Connection
loss, deadlock, ActiveRecord::Rollback and other unknown errors retain their
original classes and commit-uncertainty semantics.

No database schema, stored record, content identity or backend SPI change is
required. Run SQLite and live PostgreSQL conformance against the selected core
checkout before merging the two repositories.
