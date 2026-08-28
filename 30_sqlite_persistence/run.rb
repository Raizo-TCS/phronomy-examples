# frozen_string_literal: true

require "fileutils"
require "securerandom"

require "active_record"
require "phronomy"

require_relative "lib/active_record_sqlite_persistence"
require_relative "db/schema"

module SQLitePersistenceDemo
  class Record < ActiveRecord::Base
    self.abstract_class = true
  end

  module_function

  def run
    database_path = File.expand_path(
      ENV.fetch("PHRONOMY_SQLITE_DB", "storage/phronomy.sqlite3"),
      __dir__
    )
    FileUtils.mkdir_p(File.dirname(database_path))

    connect(database_path)
    pool = Record.connection_pool
    PhronomyExamples::Persistence::SQLiteSchema.apply!(pool)

    backend =
      PhronomyExamples::Persistence::ActiveRecordSQLite.new(
        connection_pool: pool
      )

    suffix = SecureRandom.hex(4)
    root = Phronomy::Agent::AgentRoot.create(
      agent_id: "sqlite-demo-agent-#{suffix}",
      agent_definition_id: "sqlite-reference-demo",
      agent_definition_version: 1
    )
    backend.agents.create(root)

    content_id = backend.contents.put_text("durable SQLite content")
    appended = backend.journals.append(
      root.agent_id,
      expected_position: 0,
      records: [
        Phronomy::Agent::JournalRecord.new(
          agent_id: root.agent_id,
          kind: :knowledge,
          channel: :context,
          role: :user,
          content_ref: content_id,
          context_candidate: true
        )
      ]
    )
    updated = root.with(
      agent_revision: 1,
      journal_position: appended.length,
      lifecycle_status: :active
    )
    backend.agents.save(root.agent_id, expected_revision: 0, root: updated)

    workflow_instance_id = "sqlite-demo-workflow-#{suffix}"
    backend.workflow_states.save(
      workflow_instance_id,
      expected_revision: nil,
      snapshot: {
        fields: {message: "durable Workflow state"},
        phase: "pause"
      }
    )

    puts "Created durable state:"
    puts "  database:    #{database_path}"
    puts "  agent_id:    #{root.agent_id}"
    puts "  content_id:  #{content_id}"
    puts "  journal:     #{backend.journals.head(root.agent_id)}"
    puts "  workflow_id: #{workflow_instance_id}"

    Record.connection_pool.disconnect!

    connect(database_path)
    reloaded =
      PhronomyExamples::Persistence::ActiveRecordSQLite.new(
        connection_pool: Record.connection_pool
      )

    loaded_root = reloaded.agents.load(root.agent_id)
    loaded_workflow = reloaded.workflow_states.load(workflow_instance_id)

    puts
    puts "Reloaded through a fresh ActiveRecord connection pool:"
    puts "  agent revision:     #{loaded_root.agent_revision}"
    puts "  journal position:   #{reloaded.journals.head(root.agent_id)}"
    puts "  content:            #{reloaded.contents.fetch_text(content_id)}"
    puts "  workflow revision:  #{loaded_workflow[:revision]}"
    puts "  workflow phase:     #{loaded_workflow[:snapshot]['phase']}"
  ensure
    Record.connection_pool.disconnect! if Record.connected?
  end

  def connect(database_path)
    Record.establish_connection(
      adapter: "sqlite3",
      database: database_path,
      pool: 5,
      timeout: 5_000
    )
  end
end

SQLitePersistenceDemo.run
