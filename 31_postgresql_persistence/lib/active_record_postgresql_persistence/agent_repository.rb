# frozen_string_literal: true

module PhronomyExamples
  module Persistence
    class ActiveRecordPostgreSQL < Phronomy::Persistence
      class AgentRepository < ConnectionAccess
        def create(agent_id:, agent_revision:, record:)
          key = String(agent_id)
          revision = Integer(agent_revision)
          raise Phronomy::Persistence::ConflictError, "agent_id must not be empty" if key.empty?
          raise Phronomy::Persistence::ConflictError, "agent_revision must be non-negative" if revision.negative?

          inserted = with_write_connection do |connection|
            exec_query_sql(
              connection,
              "INSERT INTO phronomy_agents (agent_id, revision, root_json) VALUES (" \
              "#{quote_value(connection, key)}, #{revision}, " \
              "#{quote_value(connection, Codec.dump_record(record))}) " \
              "ON CONFLICT (agent_id) DO NOTHING RETURNING agent_id"
            )
          end
          if inserted.empty?
            raise Phronomy::Persistence::ConflictError, "Agent already exists: #{key}"
          end
          record.copy
        end

        def load(agent_id)
          row = with_read_connection { |connection| load_row_on(connection, agent_id) }
          unless row
            raise Phronomy::Persistence::NotFoundError, "Agent not found: #{agent_id}"
          end
          Codec.load_record(row.fetch("root_json"))
        end

        def save(agent_id, expected_revision:, next_revision:, record:)
          expected = Integer(expected_revision)
          next_value = Integer(next_revision)
          unless next_value == expected + 1
            raise Phronomy::Persistence::ConflictError,
              "Agent revision must advance exactly once"
          end

          outcome = with_write_connection do |connection|
            affected = update_sql(
              connection,
              "UPDATE phronomy_agents SET revision = #{next_value}, " \
              "root_json = #{quote_value(connection, Codec.dump_record(record))} " \
              "WHERE agent_id = #{quote_value(connection, agent_id)} " \
              "AND revision = #{expected}"
            )
            if affected == 1
              :ok
            elsif load_row_on(connection, agent_id)
              :conflict
            else
              :not_found
            end
          end

          return record.copy if outcome == :ok
          if outcome == :conflict
            raise Phronomy::Persistence::ConflictError,
              "stale Agent revision for #{agent_id}"
          end
          raise Phronomy::Persistence::NotFoundError, "Agent not found: #{agent_id}"
        end

        def delete(agent_id)
          with_write_connection do |connection|
            delete_sql(connection, "DELETE FROM phronomy_agents WHERE agent_id = #{quote_value(connection, agent_id)}")
          end
          nil
        end

        private

        def load_row_on(connection, agent_id)
          select_one_sql(
            connection,
            "SELECT revision, root_json FROM phronomy_agents " \
            "WHERE agent_id = #{quote_value(connection, agent_id)}"
          )
        end
      end
    end
  end
end
