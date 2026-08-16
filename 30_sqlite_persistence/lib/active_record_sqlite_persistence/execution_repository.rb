# frozen_string_literal: true

module PhronomyExamples
  module Persistence
    class ActiveRecordSQLite < Phronomy::Persistence
      class ExecutionRepository < ConnectionAccess
        def create_active(execution)
          with_write_connection do |connection|
            if execution_exists_on?(connection, execution.execution_id)
              raise Phronomy::Persistence::ConflictError,
                    "Execution already exists: #{execution.execution_id}"
            end

            if active_for_agent_on?(connection, execution.agent_id)
              raise Phronomy::AgentBusyError,
                    "Agent already has an active execution: #{execution.agent_id}"
            end

            execute_sql(
              connection,
              "INSERT INTO phronomy_executions " \
              "(execution_id, agent_id, revision, status, active, execution_json) VALUES (" \
              "#{quote_value(connection, execution.execution_id)}, " \
              "#{quote_value(connection, execution.agent_id)}, " \
              "#{Integer(execution.execution_revision)}, " \
              "#{quote_value(connection, execution.status.to_s)}, " \
              "#{execution.active? ? 1 : 0}, " \
              "#{quote_value(connection, Codec.dump_domain(execution))})"
            )
          end

          execution
        rescue ActiveRecord::RecordNotUnique => error
          classify_admission_conflict!(execution, error)
        end

        def load(execution_id)
          row = with_read_connection do |connection|
            select_one_sql(
              connection,
              "SELECT execution_json FROM phronomy_executions " \
              "WHERE execution_id = #{quote_value(connection, execution_id)}"
            )
          end

          unless row
            raise Phronomy::Persistence::NotFoundError,
                  "Execution not found: #{execution_id}"
          end

          Codec.load_execution(row.fetch("execution_json"))
        end

        def save(execution_id, expected_revision:, execution:)
          unless execution.execution_id == execution_id
            raise Phronomy::Persistence::ConflictError,
                  "Execution identity mismatch: expected #{execution_id}, " \
                  "got #{execution.execution_id}"
          end

          unless execution.execution_revision == expected_revision + 1
            raise Phronomy::Persistence::ConflictError,
                  "Execution revision must advance exactly once"
          end

          affected = with_write_connection do |connection|
            update_sql(
              connection,
              "UPDATE phronomy_executions " \
              "SET revision = #{Integer(execution.execution_revision)}, " \
              "status = #{quote_value(connection, execution.status.to_s)}, " \
              "active = #{execution.active? ? 1 : 0}, " \
              "execution_json = #{quote_value(connection, Codec.dump_domain(execution))} " \
              "WHERE execution_id = #{quote_value(connection, execution_id)} " \
              "AND revision = #{Integer(expected_revision)}"
            )
          end

          return execution if affected == 1

          if execution_exists?(execution_id)
            raise Phronomy::Persistence::ConflictError,
                  "stale Execution revision for #{execution_id}"
          end

          raise Phronomy::Persistence::NotFoundError,
                "Execution not found: #{execution_id}"
        rescue ActiveRecord::RecordNotUnique
          raise Phronomy::AgentBusyError,
                "Agent already has an active execution: #{execution.agent_id}"
        end

        def list_active(agent_id)
          rows = with_read_connection do |connection|
            select_all_sql(
              connection,
              "SELECT execution_json FROM phronomy_executions " \
              "WHERE agent_id = #{quote_value(connection, agent_id)} " \
              "AND active = 1 ORDER BY execution_id ASC"
            )
          end

          rows.map { |row| Codec.load_execution(row.fetch("execution_json")) }.freeze
        end

        def assert_idle!(agent_id)
          busy = with_write_connection do |connection|
            active_for_agent_on?(connection, agent_id)
          end
          if busy
            raise Phronomy::AgentBusyError,
                  "Agent already has an active execution: #{agent_id}"
          end

          true
        end

        def delete(execution_id)
          with_write_connection do |connection|
            delete_sql(
              connection,
              "DELETE FROM phronomy_executions " \
              "WHERE execution_id = #{quote_value(connection, execution_id)}"
            )
          end
          nil
        end

        def delete_for_agent(agent_id)
          with_write_connection do |connection|
            delete_sql(
              connection,
              "DELETE FROM phronomy_executions " \
              "WHERE agent_id = #{quote_value(connection, agent_id)}"
            )
          end
          nil
        end

        private

        def classify_admission_conflict!(execution, original_error)
          if execution_exists?(execution.execution_id)
            raise Phronomy::Persistence::ConflictError,
                  "Execution already exists: #{execution.execution_id}"
          end

          if active_for_agent?(execution.agent_id)
            raise Phronomy::AgentBusyError,
                  "Agent already has an active execution: #{execution.agent_id}"
          end

          raise original_error
        end

        def execution_exists?(execution_id)
          with_read_connection do |connection|
            execution_exists_on?(connection, execution_id)
          end
        end

        def execution_exists_on?(connection, execution_id)
          !select_one_sql(
            connection,
            "SELECT 1 FROM phronomy_executions " \
            "WHERE execution_id = #{quote_value(connection, execution_id)} LIMIT 1"
          ).nil?
        end

        def active_for_agent?(agent_id)
          with_read_connection do |connection|
            active_for_agent_on?(connection, agent_id)
          end
        end

        def active_for_agent_on?(connection, agent_id)
          !select_one_sql(
            connection,
            "SELECT 1 FROM phronomy_executions " \
            "WHERE agent_id = #{quote_value(connection, agent_id)} " \
            "AND active = 1 LIMIT 1"
          ).nil?
        end
      end
    end
  end
end
