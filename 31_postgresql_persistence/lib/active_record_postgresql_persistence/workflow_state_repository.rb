# frozen_string_literal: true

module PhronomyExamples
  module Persistence
    class ActiveRecordPostgreSQL < Phronomy::Persistence
      class WorkflowStateRepository < ConnectionAccess
        def load(thread_id)
          row = with_read_connection do |connection|
            select_one_sql(
              connection,
              "SELECT revision, snapshot_json FROM phronomy_workflow_states " \
              "WHERE thread_id = #{quote_value(connection, thread_id)}"
            )
          end
          return nil unless row

          {
            revision: Integer(row.fetch("revision")),
            snapshot: Codec.load_workflow(row.fetch("snapshot_json"))
          }
        end

        def save(thread_id, expected_revision:, snapshot:)
          encoded = Codec.dump_workflow(snapshot)

          if expected_revision.nil?
            inserted = with_write_connection do |connection|
              exec_query_sql(
                connection,
                "INSERT INTO phronomy_workflow_states " \
                "(thread_id, revision, snapshot_json) VALUES (" \
                "#{quote_value(connection, thread_id)}, 1, " \
                "#{quote_value(connection, encoded)}) " \
                "ON CONFLICT (thread_id) DO NOTHING " \
                "RETURNING revision"
              )
            end

            if inserted.empty?
              raise Phronomy::Persistence::ConflictError,
                    "Workflow state already exists: #{thread_id}"
            end

            return 1
          end

          next_revision = Integer(expected_revision) + 1
          affected = with_write_connection do |connection|
            update_sql(
              connection,
              "UPDATE phronomy_workflow_states " \
              "SET revision = #{next_revision}, " \
              "snapshot_json = #{quote_value(connection, encoded)} " \
              "WHERE thread_id = #{quote_value(connection, thread_id)} " \
              "AND revision = #{Integer(expected_revision)}"
            )
          end

          if affected != 1
            raise Phronomy::Persistence::ConflictError,
                  "stale Workflow revision for #{thread_id}"
          end

          next_revision
        end

        def delete(thread_id, expected_revision:)
          affected = with_write_connection do |connection|
            delete_sql(
              connection,
              "DELETE FROM phronomy_workflow_states " \
              "WHERE thread_id = #{quote_value(connection, thread_id)} " \
              "AND revision = #{Integer(expected_revision)}"
            )
          end

          if affected != 1
            raise Phronomy::Persistence::ConflictError,
                  "stale Workflow revision for #{thread_id}"
          end

          nil
        end
      end
    end
  end
end
