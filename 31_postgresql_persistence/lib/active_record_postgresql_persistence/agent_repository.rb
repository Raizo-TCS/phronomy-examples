# frozen_string_literal: true

module PhronomyExamples
  module Persistence
    class ActiveRecordPostgreSQL < Phronomy::Persistence
      class AgentRepository < ConnectionAccess
        def create(root)
          agent_id = String(root.agent_id)
          if agent_id.empty?
            raise Phronomy::Persistence::ConflictError, "agent_id must not be empty"
          end

          inserted = with_write_connection do |connection|
            exec_query_sql(
              connection,
              "INSERT INTO phronomy_agents (agent_id, revision, root_json) VALUES (" \
              "#{quote_value(connection, agent_id)}, #{Integer(root.agent_revision)}, " \
              "#{quote_value(connection, Codec.dump_domain(root))}) " \
              "ON CONFLICT (agent_id) DO NOTHING " \
              "RETURNING agent_id"
            )
          end

          if inserted.empty?
            raise Phronomy::Persistence::ConflictError,
                  "Agent already exists: #{agent_id}"
          end

          root
        end

        def load(agent_id)
          row = with_read_connection do |connection|
            load_row_on(connection, agent_id)
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

          outcome = with_write_connection do |connection|
            affected = update_sql(
              connection,
              "UPDATE phronomy_agents " \
              "SET revision = #{Integer(root.agent_revision)}, " \
              "root_json = #{quote_value(connection, Codec.dump_domain(root))} " \
              "WHERE agent_id = #{quote_value(connection, agent_id)} " \
              "AND revision = #{Integer(expected_revision)}"
            )

            if affected == 1
              :ok
            elsif load_row_on(connection, agent_id)
              :conflict
            else
              :not_found
            end
          end

          return root if outcome == :ok

          if outcome == :conflict
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
