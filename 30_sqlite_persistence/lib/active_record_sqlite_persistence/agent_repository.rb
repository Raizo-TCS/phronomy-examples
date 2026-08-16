# frozen_string_literal: true

module PhronomyExamples
  module Persistence
    class ActiveRecordSQLite < Phronomy::Persistence
      class AgentRepository < ConnectionAccess
        def create(root)
          agent_id = String(root.agent_id)
          if agent_id.empty?
            raise Phronomy::Persistence::ConflictError, "agent_id must not be empty"
          end

          with_write_connection do |connection|
            execute_sql(
              connection,
              "INSERT INTO phronomy_agents (agent_id, revision, root_json) VALUES (" \
              "#{quote_value(connection, agent_id)}, #{Integer(root.agent_revision)}, " \
              "#{quote_value(connection, Codec.dump_domain(root))})"
            )
          end

          root
        rescue ActiveRecord::RecordNotUnique
          raise Phronomy::Persistence::ConflictError,
                "Agent already exists: #{agent_id}"
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
            raise Phronomy::Persistence::NotFoundError,
                  "Agent not found: #{agent_id}"
          end

          Codec.load_agent_root(row.fetch("root_json"))
        end

        def save(agent_id, expected_revision:, root:)
          unless root.agent_id == agent_id
            raise Phronomy::Persistence::ConflictError,
                  "Agent identity mismatch: expected #{agent_id}, got #{root.agent_id}"
          end

          unless root.agent_revision == expected_revision + 1
            raise Phronomy::Persistence::ConflictError,
                  "Agent revision must advance exactly once"
          end

          affected = with_write_connection do |connection|
            update_sql(
              connection,
              "UPDATE phronomy_agents " \
              "SET revision = #{Integer(root.agent_revision)}, " \
              "root_json = #{quote_value(connection, Codec.dump_domain(root))} " \
              "WHERE agent_id = #{quote_value(connection, agent_id)} " \
              "AND revision = #{Integer(expected_revision)}"
            )
          end

          return root if affected == 1

          if agent_exists?(agent_id)
            raise Phronomy::Persistence::ConflictError,
                  "stale Agent revision for #{agent_id}"
          end

          raise Phronomy::Persistence::NotFoundError,
                "Agent not found: #{agent_id}"
        end

        def delete(agent_id)
          with_write_connection do |connection|
            delete_sql(
              connection,
              "DELETE FROM phronomy_agents " \
              "WHERE agent_id = #{quote_value(connection, agent_id)}"
            )
          end
          nil
        end

        private

        def agent_exists?(agent_id)
          with_read_connection do |connection|
            !select_one_sql(
              connection,
              "SELECT 1 FROM phronomy_agents " \
              "WHERE agent_id = #{quote_value(connection, agent_id)} LIMIT 1"
            ).nil?
          end
        end
      end
    end
  end
end
