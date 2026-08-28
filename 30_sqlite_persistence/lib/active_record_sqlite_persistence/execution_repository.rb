# frozen_string_literal: true

module PhronomyExamples
  module Persistence
    class ActiveRecordSQLite < Phronomy::Persistence
      class ExecutionRepository < ConnectionAccess
        def create_active(execution_id:, agent_id:, execution_revision:, record:)
          execution_key = String(execution_id)
          agent_key = String(agent_id)
          revision = Integer(execution_revision)
          raise Phronomy::Persistence::ConflictError, "execution_id must not be empty" if execution_key.empty?
          raise Phronomy::Persistence::ConflictError, "agent_id must not be empty" if agent_key.empty?
          raise Phronomy::Persistence::ConflictError, "execution_revision must be non-negative" if revision.negative?

          with_write_connection do |connection|
            if execution_exists_on?(connection, execution_key)
              raise Phronomy::Persistence::ConflictError,
                "Execution already exists: #{execution_key}"
            end
            if active_for_agent_on?(connection, agent_key)
              raise Phronomy::AgentBusyError,
                "Agent already has an active execution: #{agent_key}"
            end
            execute_sql(
              connection,
              "INSERT INTO phronomy_executions " \
              "(execution_id, agent_id, revision, status, active, execution_json) VALUES (" \
              "#{quote_value(connection, execution_key)}, " \
              "#{quote_value(connection, agent_key)}, #{revision}, 'opaque', 1, " \
              "#{quote_value(connection, Codec.dump_record(record))})"
            )
          end
          record.copy
        rescue ActiveRecord::RecordNotUnique => e
          if active_for_agent?(agent_key)
            raise Phronomy::AgentBusyError,
              "Agent already has an active execution: #{agent_key}"
          end
          raise Phronomy::Persistence::ConflictError, e.message
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
          Codec.load_record(row.fetch("execution_json"))
        end

        def save(execution_id, expected_revision:, next_revision:, agent_id:, active:, record:)
          expected = Integer(expected_revision)
          next_value = Integer(next_revision)
          unless next_value == expected + 1
            raise Phronomy::Persistence::ConflictError,
              "Execution revision must advance exactly once"
          end
          unless active.equal?(true) || active.equal?(false)
            raise Phronomy::Persistence::ConflictError,
              "Execution active metadata must be true or false"
          end

          outcome = with_write_connection do |connection|
            stored = select_one_sql(
              connection,
              "SELECT agent_id FROM phronomy_executions " \
              "WHERE execution_id = #{quote_value(connection, execution_id)}"
            )
            next :not_found unless stored
            next :identity_conflict unless stored.fetch("agent_id") == agent_id.to_s
            if active && active_for_agent_on?(connection, agent_id, excluding_execution_id: execution_id)
              next :agent_busy
            end

            affected = update_sql(
              connection,
              "UPDATE phronomy_executions SET " \
              "revision = #{next_value}, active = #{active ? 1 : 0}, " \
              "execution_json = #{quote_value(connection, Codec.dump_record(record))} " \
              "WHERE execution_id = #{quote_value(connection, execution_id)} " \
              "AND revision = #{expected}"
            )
            affected == 1 ? :ok : :conflict
          end

          case outcome
          when :ok then record.copy
          when :not_found
            raise Phronomy::Persistence::NotFoundError, "Execution not found: #{execution_id}"
          when :identity_conflict
            raise Phronomy::Persistence::ConflictError, "Execution Agent identity mismatch: #{execution_id}"
          when :agent_busy
            raise Phronomy::AgentBusyError, "Agent already has an active execution: #{agent_id}"
          else
            raise Phronomy::Persistence::ConflictError, "stale Execution revision for #{execution_id}"
          end
        end

        def list_active(agent_id)
          rows = with_read_connection do |connection|
            select_all_sql(
              connection,
              "SELECT execution_json FROM phronomy_executions " \
              "WHERE agent_id = #{quote_value(connection, agent_id)} AND active = 1 " \
              "ORDER BY execution_id ASC"
            )
          end
          rows.map { |row| Codec.load_record(row.fetch("execution_json")) }.freeze
        end

        def assert_idle!(agent_id)
          busy = with_write_connection { |connection| active_for_agent_on?(connection, agent_id) }
          if busy
            raise Phronomy::AgentBusyError,
              "Agent already has an active execution: #{agent_id}"
          end
          true
        end

        def delete(execution_id)
          with_write_connection do |connection|
            delete_sql(connection, "DELETE FROM phronomy_executions WHERE execution_id = #{quote_value(connection, execution_id)}")
          end
          nil
        end

        def delete_for_agent(agent_id)
          with_write_connection do |connection|
            delete_sql(connection, "DELETE FROM phronomy_executions WHERE agent_id = #{quote_value(connection, agent_id)}")
          end
          nil
        end

        private

        def execution_exists_on?(connection, execution_id)
          !select_one_sql(
            connection,
            "SELECT 1 FROM phronomy_executions WHERE execution_id = #{quote_value(connection, execution_id)} LIMIT 1"
          ).nil?
        end

        def active_for_agent?(agent_id)
          with_read_connection { |connection| active_for_agent_on?(connection, agent_id) }
        end

        def active_for_agent_on?(connection, agent_id, excluding_execution_id: nil)
          query = +"SELECT 1 FROM phronomy_executions " \
                   "WHERE agent_id = #{quote_value(connection, agent_id)} AND active = 1"
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
