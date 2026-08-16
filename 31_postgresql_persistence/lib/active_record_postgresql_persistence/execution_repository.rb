# frozen_string_literal: true

module PhronomyExamples
  module Persistence
    class ActiveRecordPostgreSQL < Phronomy::Persistence
      class ExecutionRepository < ConnectionAccess
        def create_active(execution)
          with_write_connection do |connection|
            lock_agent_row!(connection, execution.agent_id)

            if execution_exists_on?(connection, execution.execution_id)
              raise Phronomy::Persistence::ConflictError,
                    "Execution already exists: #{execution.execution_id}"
            end

            if active_for_agent_on?(connection, execution.agent_id)
              raise Phronomy::AgentBusyError,
                    "Agent already has an active execution: #{execution.agent_id}"
            end

            inserted = exec_query_sql(
              connection,
              "INSERT INTO phronomy_executions " \
              "(execution_id, agent_id, revision, status, active, execution_json) VALUES (" \
              "#{quote_value(connection, execution.execution_id)}, " \
              "#{quote_value(connection, execution.agent_id)}, " \
              "#{Integer(execution.execution_revision)}, " \
              "#{quote_value(connection, execution.status.to_s)}, " \
              "#{sql_boolean(execution.active?)}, " \
              "#{quote_value(connection, Codec.dump_domain(execution))}) " \
              "ON CONFLICT DO NOTHING " \
              "RETURNING execution_id"
            )

            if inserted.empty?
              if execution_exists_on?(connection, execution.execution_id)
                raise Phronomy::Persistence::ConflictError,
                      "Execution already exists: #{execution.execution_id}"
              end

              if active_for_agent_on?(connection, execution.agent_id)
                raise Phronomy::AgentBusyError,
                      "Agent already has an active execution: #{execution.agent_id}"
              end

              raise Phronomy::Persistence::ConflictError,
                    "Execution admission constraint conflict: #{execution.execution_id}"
            end
          end

          execution
        end

        def load(execution_id)
          row = with_read_connection do |connection|
            execution_row_on(connection, execution_id)
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

          outcome = with_write_connection do |connection|
            stored = execution_row_on(connection, execution_id)
            next :not_found unless stored

            stored_agent_id = stored.fetch("agent_id")
            lock_agent_row!(connection, stored_agent_id)

            # The row may have been deleted while waiting for the Agent lock.
            stored = execution_row_on(connection, execution_id)
            next :not_found unless stored

            unless execution.agent_id == stored.fetch("agent_id")
              next :identity_conflict
            end

            if execution.active? && active_for_agent_on?(
              connection,
              execution.agent_id,
              excluding_execution_id: execution_id
            )
              next :agent_busy
            end

            affected = update_sql(
              connection,
              "UPDATE phronomy_executions " \
              "SET revision = #{Integer(execution.execution_revision)}, " \
              "status = #{quote_value(connection, execution.status.to_s)}, " \
              "active = #{sql_boolean(execution.active?)}, " \
              "execution_json = #{quote_value(connection, Codec.dump_domain(execution))} " \
              "WHERE execution_id = #{quote_value(connection, execution_id)} " \
              "AND revision = #{Integer(expected_revision)}"
            )

            if affected == 1
              :ok
            elsif execution_row_on(connection, execution_id)
              :conflict
            else
              :not_found
            end
          end

          case outcome
          when :ok
            execution
          when :agent_busy
            raise Phronomy::AgentBusyError,
                  "Agent already has an active execution: #{execution.agent_id}"
          when :identity_conflict
            raise Phronomy::Persistence::ConflictError,
                  "Execution Agent identity mismatch for #{execution_id}"
          when :conflict
            raise Phronomy::Persistence::ConflictError,
                  "stale Execution revision for #{execution_id}"
          else
            raise Phronomy::Persistence::NotFoundError,
                  "Execution not found: #{execution_id}"
          end
        end

        def list_active(agent_id)
          rows = with_read_connection do |connection|
            select_all_sql(
              connection,
              "SELECT execution_json FROM phronomy_executions " \
              "WHERE agent_id = #{quote_value(connection, agent_id)} " \
              "AND active IS TRUE ORDER BY execution_id ASC"
            )
          end

          rows.map { |row| Codec.load_execution(row.fetch("execution_json")) }.freeze
        end

        def assert_idle!(agent_id)
          busy = with_write_connection do |connection|
            lock_agent_row!(connection, agent_id)
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
            row = execution_row_on(connection, execution_id)
            if row
              lock_agent_row(connection, row.fetch("agent_id"))
              delete_sql(
                connection,
                "DELETE FROM phronomy_executions " \
                "WHERE execution_id = #{quote_value(connection, execution_id)}"
              )
            end
          end
          nil
        end

        def delete_for_agent(agent_id)
          with_write_connection do |connection|
            lock_agent_row(connection, agent_id)
            delete_sql(
              connection,
              "DELETE FROM phronomy_executions " \
              "WHERE agent_id = #{quote_value(connection, agent_id)}"
            )
          end
          nil
        end

        private

        def execution_exists_on?(connection, execution_id)
          !select_one_sql(
            connection,
            "SELECT 1 FROM phronomy_executions " \
            "WHERE execution_id = #{quote_value(connection, execution_id)} LIMIT 1"
          ).nil?
        end

        def execution_row_on(connection, execution_id)
          select_one_sql(
            connection,
            "SELECT agent_id, revision, execution_json FROM phronomy_executions " \
            "WHERE execution_id = #{quote_value(connection, execution_id)}"
          )
        end

        def active_for_agent_on?(connection, agent_id, excluding_execution_id: nil)
          query = +"SELECT 1 FROM phronomy_executions " \
                   "WHERE agent_id = #{quote_value(connection, agent_id)} " \
                   "AND active IS TRUE"
          if excluding_execution_id
            query << " AND execution_id <> #{quote_value(connection, excluding_execution_id)}"
          end
          query << " LIMIT 1"

          !select_one_sql(connection, query).nil?
        end
      end
    end
  end
end
