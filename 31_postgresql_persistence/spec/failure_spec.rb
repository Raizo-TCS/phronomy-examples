# frozen_string_literal: true

require "spec_helper"

RSpec.describe "ActiveRecord PostgreSQL Persistence storage failures" do
  it "does not relabel a terminated PostgreSQL session as an optimistic conflict" do
    persistence, = build_postgresql_persistence
    _control_backend, control_pool = build_postgresql_persistence

    root = build_agent_root(prefix: "terminated-session")
    persistence.agents.create(root)

    error = begin
      persistence.connection_pool.with_connection do |target_connection|
        target_connection.transaction do
          pid = postgresql_backend_pid(target_connection)

          control_pool.with_connection do |control_connection|
            terminated = control_connection.select_value(
              "SELECT pg_terminate_backend(#{Integer(pid)}, 5000)"
            )
            unless terminated == true || terminated.to_s == "t"
              raise "PostgreSQL did not terminate backend PID #{pid}"
            end
          end

          tx =
            PhronomyExamples::Persistence::ActiveRecordPostgreSQL::TransactionView.new(
              connection_pool: persistence.connection_pool,
              connection: target_connection
            )
          tx.agents.load(root.agent_id)
        end
      end
      nil
    rescue StandardError => e
      e
    end

    expect(error).not_to be_nil
    expect(error).not_to be_a(Phronomy::Persistence::ConflictError)
    expect(error).not_to be_a(Phronomy::AgentBusyError)
    expect(error).not_to be_a(Phronomy::Persistence::NotFoundError)
  end
  it "does not relabel an unavailable PostgreSQL endpoint as an optimistic conflict" do
    const_name = :"PhronomyUnavailablePostgreSQLBase_#{SecureRandom.hex(8).upcase}"
    record_class = Object.const_set(const_name, Class.new(ActiveRecord::Base))
    record_class.abstract_class = true
    record_class.establish_connection(
      "postgresql://postgres:postgres@127.0.0.1:1/phronomy_unavailable?connect_timeout=1"
    )

    error = begin
      backend = PhronomyExamples::Persistence::ActiveRecordPostgreSQL.new(
        connection_pool: record_class.connection_pool
      )
      backend.agents.load("connection-failure-probe")
      nil
    rescue StandardError => e
      e
    end

    expect(error).not_to be_nil
    expect(error).not_to be_a(Phronomy::Persistence::ConflictError)
    expect(error).not_to be_a(Phronomy::AgentBusyError)
    expect(error).not_to be_a(Phronomy::Persistence::NotFoundError)
  ensure
    record_class&.connection_pool&.disconnect! rescue nil
    Object.send(:remove_const, const_name) if const_name && Object.const_defined?(const_name)
  end

end
