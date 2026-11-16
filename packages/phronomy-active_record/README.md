# phronomy-active_record (unpublished 0.1.0)

<!-- PHRONOMY_RELEASE_OVERVIEW_BEGIN -->
Optional SQL persistence for published Phronomy `~> 0.35.0`. The existing
examples' neutral ActiveRecord driver and resource mappings are maintained
here. Core does not require this package, ActiveRecord, SQLite or PostgreSQL.
The package uses the public `PersistenceComposition.resources` catalog.
<!-- PHRONOMY_RELEASE_OVERVIEW_END -->

## Install and configure

<!-- PHRONOMY_RELEASE_INSTALL_BEGIN -->
The application selects the published core and the optional database package
together. The SQL package itself is still distributed as repository source.

For example, a local SQLite application declares the published core, the
package checkout and its database driver:

```ruby
gem "phronomy", "~> 0.35.0"
gem "phronomy-active_record", path: "/path/to/phronomy-active_record",
  require: "phronomy/active_record"
gem "sqlite3", ">= 2.10.2"
```

The examples repository reads the same core requirement from
`Gemfile.phronomy`. For coordinated local core development, select the
matching checkout through `PHRONOMY_PATH` and run `scripts/update_phronomy.sh`.
<!-- PHRONOMY_RELEASE_INSTALL_END -->

Ruby >= 3.2, ActiveRecord >= 7.1 and < 9 are accepted dependencies. Actual Ruby
requirements also depend on the chosen ActiveRecord version. Compatibility
verification uses the existing SQLite and PostgreSQL contract suites; a version
range is not a claim that every DB/Ruby/ActiveRecord combination was tested.

```ruby
require "phronomy/active_record"
stores = PhronomyActiveRecord.build(
  connection_pool: ActiveRecord::Base.connection_pool,
  dialect: :sqlite # :postgresql for PostgreSQL
)
agent = MyAgent.create(agent_id: "conversation-1", persistence: stores.agent)
puts agent.invoke("Hello").fetch(:output)
# Pass stores.multi_agent to Team and stores.workflow to Workflow definitions.
```

`build` assembles the existing PersistenceComposition::Stores over ONE backend.
It does not create tables, change connection settings, close the application pool,
start Runtime, or decide domain retry/recovery/finalization policies. Borrowed
connections are returned through ActiveRecord's pool API.

The mapping obtains `PersistenceComposition.resources`, a frozen list of the
canonical domain and content Resource objects. Composition owns the catalog;
this package owns SQL table/column mapping and connection adaptation. The package
does not read private core schema modules or duplicate their declarations.

## Explicit new-database migration

Rails: `bin/rails generate phronomy:install`, review the copied migration, then
`bin/rails db:migrate`. The generator only copies a migration; it does not change
initializers or run DDL. The migration invokes immutable `SchemaV1` assets.

Without Rails, establish an application-owned ActiveRecord connection, then run
this once under your deployment migration procedure:

```ruby
require "phronomy/active_record/schema_v1"
ActiveRecord::Base.connection_pool.with_connection do |connection|
  PhronomyActiveRecord::SchemaV1.install!(connection: connection)
end
```

Alternatively copy `db/migrate/001_create_phronomy_tables.rb` into your migration
runner. Do not call schema installation from request handlers or `build`.
Rollback is deliberately irreversible: archive domain data and review removal
separately. Schema provisioning does not migrate old domain record formats.

Existing v0.28 reference databases need no table, column, index, identifier or
codec conversion. Existing Rails migration history remains unchanged; do not
rerun a new-database migration as an old-data conversion. Pre-unit4 data still
requires the examples' explicit offline exporter/converter/importer. SQLite
migration tests remain separate from normal PostgreSQL contract tests.

## Source ownership and verification

| Former examples path | Authoritative package path |
|---|---|
| `shared/storage/*.rb` | `lib/phronomy/active_record/storage/*.rb` |
| `shared/persistence_storage_mapping.rb` | `lib/phronomy/active_record/persistence_storage_mapping.rb` |
| `30_sqlite_persistence/db/schema.rb` | `lib/phronomy/active_record/schema_v1/sqlite.rb` |
| `31_postgresql_persistence/db/schema.rb` | `lib/phronomy/active_record/schema_v1/postgresql.rb` |

The former `shared/storage/*.rb` imports and `PhronomyExamples::Storage` alias
have been removed. Load the package and use its namespace directly:

```ruby
require "phronomy/active_record"
codec = PhronomyActiveRecord::Storage::Codec
```

The same namespace provides `Backend`, `Records`, `Streams`, `Blobs` and
`Mapping`. These are the existing implementations; no SQL behavior or stored
format changes. Keep the local `path:` dependency shown above until the package
is published. The resource-mapping and schema aliases listed in the table remain
in use by examples 30/31 and the offline migration CLI.

The examples' historical Rails migrations and offline snapshot tooling remain
application/deployment history. Future schema changes require new versioned
assets and explicit upgrade migrations rather than editing SchemaV1.

Run the examples' SQLite and PostgreSQL suites against a local core with
`PHRONOMY_PATH`. The package contains no provider credentials or implicit DB
configuration. Real PostgreSQL verification requires a test database.
