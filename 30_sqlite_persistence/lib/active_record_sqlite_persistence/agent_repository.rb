# frozen_string_literal: true

module PhronomyExamples
  module Persistence
    class ActiveRecordSQLite < Phronomy::Persistence
      class AgentRepository < ConnectionAccess
        def create(agent_id:, agent_revision:, record:)
          key = String(agent_id)
          revision = Integer(agent_revision)
          raise Phronomy::Persistence::ConflictError, "agent_id must not be empty" if key.empty?
          raise Phronomy::Persistence::ConflictError, "agent_revision must be non-negative" if revision.negative?

          with_write_connection do |connection|
            execute_sql(
              connection,
              "INSERT INTO phronomy_agents (agent_id, revision, root_json) VALUES (" \
              "#{quote_value(connection, key)}, #{revision}, " \
              "#{quote_value(connection, Codec.dump_record(record))})"
            )
          end
          record.copy
        rescue ActiveRecord::RecordNotUnique
          raise Phronomy::Persistence::ConflictError, "Agent already exists: #{key}"
        end

        def load(agent_id)
          row = with_read_connection do |connection|
            select_one_sql(
              connection,
              "SELECT root_json FROM phronomy_agents " \
              "WHERE agent_id = #{quote_value(connection, agent_id)}"
            )
          end
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

          affected = with_write_connection do |connection|
            update_sql(
              connection,
              "UPDATE phronomy_agents SET " \
              "revision = #{next_value}, " \
              "root_json = #{quote_value(connection, Codec.dump_record(record))} " \
              "WHERE agent_id = #{quote_value(connection, agent_id)} " \
              "AND revision = #{expected}"
            )
          end
          return record.copy if affected == 1

          exists = with_read_connection do |connection|
            !select_one_sql(
              connection,
              "SELECT 1 FROM phronomy_agents " \
              "WHERE agent_id = #{quote_value(connection, agent_id)} LIMIT 1"
            ).nil?
          end
          if exists
            raise Phronomy::Persistence::ConflictError,
              "stale Agent revision for #{agent_id}"
          end
          raise Phronomy::Persistence::NotFoundError, "Agent not found: #{agent_id}"
        end

        def delete(agent_id)
          with_write_connection do |connection|
            delete_sql(
              connection,
              "DELETE FROM phronomy_agents WHERE agent_id = #{quote_value(connection, agent_id)}"
            )
          end
          nil
        end
      end
    end
  end
end
