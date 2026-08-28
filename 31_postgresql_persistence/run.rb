# frozen_string_literal: true

require "securerandom"

require "active_record"
require "phronomy"

require_relative "lib/active_record_postgresql_persistence"
require_relative "db/schema"

DATABASE_URL = ENV.fetch(
  "PHRONOMY_POSTGRES_URL",
  "postgresql://postgres:postgres@127.0.0.1:5432/phronomy_persistence_test"
)

def build_pool(name, database_url)
  klass = Object.const_set(name, Class.new(ActiveRecord::Base))
  klass.abstract_class = true
  klass.establish_connection(database_url)
  [klass, klass.connection_pool]
end

first_class = nil
second_class = nil
first_pool = nil
second_pool = nil

begin
  first_class, first_pool =
    build_pool(:PhronomyPostgreSQLDemoFirstBase, DATABASE_URL)

  PhronomyExamples::Persistence::PostgreSQLSchema.apply!(first_pool)

  first_backend =
    PhronomyExamples::Persistence::ActiveRecordPostgreSQL.new(
      connection_pool: first_pool
    )

  root = Phronomy::Agent::AgentRoot.create(
    agent_id: "postgres-demo-agent-#{SecureRandom.uuid}",
    agent_definition_id: "postgres-reference-agent",
    agent_definition_version: 1
  )
  first_backend.agents.create(root)

  content_id = first_backend.contents.put_text("durable PostgreSQL content")
  appended = first_backend.journals.append(
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
  first_backend.agents.save(
    root.agent_id,
    expected_revision: 0,
    root: updated
  )

  input_record = Phronomy::Agent::JournalRecord.new(
    agent_id: root.agent_id,
    kind: :input_received,
    channel: :external,
    role: :user,
    context_candidate: false
  )
  execution = Phronomy::Agent::AgentExecution.start(
    agent_root: updated,
    input_record: input_record
  )
  first_backend.executions.create_active(execution)

  workflow_instance_id = "postgres-demo-workflow-#{SecureRandom.uuid}"
  first_backend.workflow_states.save(
    thread_id,
    expected_revision: nil,
    snapshot: {
      fields: {value: "persisted"},
      phase: "pause"
    }
  )

  puts "Stored durable state:"
  puts "  Agent:     #{root.agent_id}"
  puts "  Content:   #{content_id}"
  puts "  Journal:   #{first_backend.journals.head(root.agent_id)} record(s)"
  puts "  Execution: #{execution.execution_id}"
  puts "  Workflow:  #{workflow_instance_id}"

  first_pool.disconnect!
  first_pool = nil

  second_class, second_pool =
    build_pool(:PhronomyPostgreSQLDemoSecondBase, DATABASE_URL)

  second_backend =
    PhronomyExamples::Persistence::ActiveRecordPostgreSQL.new(
      connection_pool: second_pool
    )

  reloaded_root = second_backend.agents.load(root.agent_id)
  reloaded_execution = second_backend.executions.load(execution.execution_id)
  reloaded_workflow = second_backend.workflow_states.load(workflow_instance_id)

  puts
  puts "Reloaded through a fresh ActiveRecord pool:"
  puts "  Agent revision:      #{reloaded_root.agent_revision}"
  puts "  Journal position:    #{second_backend.journals.head(root.agent_id)}"
  puts "  Content text:        #{second_backend.contents.fetch_text(content_id)}"
  puts "  Execution revision:  #{reloaded_execution.execution_revision}"
  puts "  Workflow revision:   #{reloaded_workflow.fetch(:revision)}"
  puts "  Workflow phase:      #{reloaded_workflow.fetch(:snapshot).fetch("phase")}"
ensure
  first_pool&.disconnect!
  second_pool&.disconnect!

end
