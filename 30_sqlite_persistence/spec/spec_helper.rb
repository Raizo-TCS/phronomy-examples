# frozen_string_literal: true

require "fileutils"
require "securerandom"
require "tmpdir"

require "active_record"
require "phronomy"

require_relative "../lib/active_record_sqlite_persistence"
require_relative "../db/schema"

module SQLitePersistenceSpecSupport
  def build_sqlite_persistence(database_path: nil, pool_size: 10, timeout: 5_000)
    database_path ||= File.join(
      @sqlite_persistence_tmpdir,
      "phronomy-#{SecureRandom.hex(6)}.sqlite3"
    )

    # AR 8.1+ requires establish_connection on a named class; give each base a unique name.
    const_name = :"PhronomySQLiteBase_#{SecureRandom.hex(8).upcase}"
    record_class = Object.const_set(const_name, Class.new(ActiveRecord::Base))
    record_class.abstract_class = true
    record_class.establish_connection(
      adapter: "sqlite3",
      database: database_path,
      pool: pool_size,
      timeout: timeout
    )

    pool = record_class.connection_pool
    PhronomyExamples::Persistence::SQLiteSchema.apply!(pool)
    @sqlite_persistence_pools << pool
    @sqlite_record_classes << const_name

    [
      PhronomyExamples::Persistence::ActiveRecordSQLite.new(connection_pool: pool),
      pool,
      database_path
    ]
  end

  def build_agent_root(prefix: "sqlite-agent")
    Phronomy::Agent::AgentRoot.create(
      agent_id: "#{prefix}-#{SecureRandom.uuid}",
      agent_definition_id: "sqlite-reference-agent",
      definition_version: 1
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
    threads.map(&:value)
  ensure
    threads&.each { |thread| thread.kill if thread.alive? }
  end
end

RSpec.configure do |config|
  config.include SQLitePersistenceSpecSupport

  config.around do |example|
    Dir.mktmpdir("phronomy-sqlite-spec-") do |dir|
      @sqlite_persistence_tmpdir = dir
      @sqlite_persistence_pools = []
      @sqlite_record_classes = []
      example.run
    ensure
      @sqlite_persistence_pools.reverse_each do |pool|
        pool.disconnect! rescue nil
      end
      @sqlite_record_classes.each do |name|
        Object.send(:remove_const, name) if Object.const_defined?(name)
      end
    end
  end
end
