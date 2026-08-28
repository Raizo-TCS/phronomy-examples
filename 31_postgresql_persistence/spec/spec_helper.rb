# frozen_string_literal: true

require "securerandom"
require "timeout"

require "active_record"
require "phronomy"

require_relative "../lib/active_record_postgresql_persistence"
require_relative "../db/schema"

module PostgreSQLPersistenceSpecSupport
  POSTGRES_URL = ENV.fetch(
    "PHRONOMY_POSTGRES_URL",
    "postgresql://postgres:postgres@127.0.0.1:5432/phronomy_persistence_test"
  )

  def build_postgresql_persistence(database_url: POSTGRES_URL)
    const_name = :"PhronomyPostgreSQLBase_#{SecureRandom.hex(8).upcase}"
    record_class = Object.const_set(const_name, Class.new(ActiveRecord::Base))
    record_class.abstract_class = true
    record_class.establish_connection(database_url)

    pool = record_class.connection_pool
    @postgresql_persistence_pools << pool
    @postgresql_record_classes << const_name

    [
      PhronomyExamples::Persistence::ActiveRecordPostgreSQL.new(
        connection_pool: pool
      ),
      pool
    ]
  end

  def reset_postgresql_schema!
    const_name = :"PhronomyPostgreSQLSchemaBase_#{SecureRandom.hex(8).upcase}"
    record_class = Object.const_set(const_name, Class.new(ActiveRecord::Base))
    record_class.abstract_class = true
    record_class.establish_connection(POSTGRES_URL)
    pool = record_class.connection_pool

    PhronomyExamples::Persistence::PostgreSQLSchema.reset!(pool)
  ensure
    pool&.disconnect!
    Object.send(:remove_const, const_name) if const_name && Object.const_defined?(const_name)
  end

  def build_agent_root(prefix: "postgres-agent")
    Phronomy::Agent::AgentRoot.create(
      agent_id: "#{prefix}-#{SecureRandom.uuid}",
      agent_definition_id: "postgres-reference-agent",
      agent_definition_version: 1
    )
  end

  def build_execution(root)
    record = Phronomy::Agent::JournalRecord.new(
      agent_id: root.agent_id,
      kind: :input_received,
      channel: :external,
      role: :user,
      context_candidate: false
    )
    Phronomy::Agent::AgentExecution.start(
      agent_root: root,
      input_record: record
    )
  end

  def build_journal_record(agent_id)
    Phronomy::Agent::JournalRecord.new(
      agent_id: agent_id,
      kind: :knowledge,
      channel: :context,
      role: :user,
      context_candidate: true
    )
  end

  def run_concurrently(*operations)
    ready = Queue.new
    start = Queue.new

    threads = operations.map do |operation|
      Thread.new do
        ready << true
        start.pop
        begin
          [:ok, operation.call]
        rescue StandardError => e
          [:error, e]
        end
      end
    end

    operations.length.times { ready.pop }
    operations.length.times { start << true }
    threads.map { |thread| Timeout.timeout(15) { thread.value } }
  ensure
    threads&.each { |thread| thread.kill if thread.alive? }
  end

  def with_bound_postgresql_transaction(persistence)
    persistence.connection_pool.with_connection do |connection|
      connection.transaction do
        tx =
          PhronomyExamples::Persistence::ActiveRecordPostgreSQL::TransactionView.build(
            persistence: persistence,
            connection_pool: persistence.connection_pool,
            connection: connection
          )
        yield tx, connection
      end
    end
  end

  def postgresql_backend_pid(connection)
    Integer(connection.select_value("SELECT pg_backend_pid()"))
  end

  def wait_until_postgresql_blocked(persistence, backend_pid, timeout: 5)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout

    loop do
      blocker_count = persistence.connection_pool.with_connection do |connection|
        Integer(
          connection.select_value(
            "SELECT cardinality(pg_blocking_pids(#{Integer(backend_pid)}))"
          )
        )
      end

      return true if blocker_count.positive?

      if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        raise Timeout::Error,
              "PostgreSQL backend #{backend_pid} did not enter a lock wait"
      end

      sleep 0.01
    end
  end

  def thread_value(thread, timeout: 15)
    Timeout.timeout(timeout) { thread.value }
  ensure
    thread.kill if thread&.alive?
  end
end

RSpec.configure do |config|
  config.include PostgreSQLPersistenceSpecSupport

  config.around do |example|
    @postgresql_persistence_pools = []
    @postgresql_record_classes = []

    begin
      example.run
    ensure
      @postgresql_persistence_pools.reverse_each do |pool|
        pool.disconnect! rescue nil
      end
      @postgresql_record_classes.each do |name|
        Object.send(:remove_const, name) if Object.const_defined?(name)
      end
    end
  end

  config.before do
    reset_postgresql_schema!
  end
end
