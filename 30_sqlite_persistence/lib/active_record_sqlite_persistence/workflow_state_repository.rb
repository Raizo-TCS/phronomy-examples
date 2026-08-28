# frozen_string_literal: true

module PhronomyExamples
  module Persistence
    class ActiveRecordSQLite < Phronomy::Persistence
      class WorkflowStateRepository < ConnectionAccess
        def load(workflow_instance_id)
          row = with_read_connection do |connection|
            select_one_sql(
              connection,
              "SELECT snapshot_json FROM phronomy_workflow_states " \
              "WHERE thread_id = #{quote_value(connection, workflow_instance_id)}"
            )
          end
          row ? Codec.load_record(row.fetch("snapshot_json")) : nil
        end

        def save(workflow_instance_id, expected_revision:, next_revision:, record:)
          expected = expected_revision.nil? ? nil : Integer(expected_revision)
          next_value = Integer(next_revision)
          expected_next = expected.nil? ? 1 : expected + 1
          unless next_value == expected_next
            raise Phronomy::Persistence::ConflictError,
              "Workflow revision must advance exactly once"
          end

          if expected.nil?
            with_write_connection do |connection|
              execute_sql(
                connection,
                "INSERT INTO phronomy_workflow_states (thread_id, revision, snapshot_json) VALUES (" \
                "#{quote_value(connection, workflow_instance_id)}, #{next_value}, " \
                "#{quote_value(connection, Codec.dump_record(record))})"
              )
            end
            return record.copy
          end

          affected = with_write_connection do |connection|
            update_sql(
              connection,
              "UPDATE phronomy_workflow_states SET revision = #{next_value}, " \
              "snapshot_json = #{quote_value(connection, Codec.dump_record(record))} " \
              "WHERE thread_id = #{quote_value(connection, workflow_instance_id)} " \
              "AND revision = #{expected}"
            )
          end
          unless affected == 1
            raise Phronomy::Persistence::ConflictError,
              "stale Workflow revision for #{workflow_instance_id}"
          end
          record.copy
        rescue ActiveRecord::RecordNotUnique
          raise Phronomy::Persistence::ConflictError,
            "Workflow state already exists: #{workflow_instance_id}"
        end

        def delete(workflow_instance_id, expected_revision:)
          affected = with_write_connection do |connection|
            delete_sql(
              connection,
              "DELETE FROM phronomy_workflow_states " \
              "WHERE thread_id = #{quote_value(connection, workflow_instance_id)} " \
              "AND revision = #{Integer(expected_revision)}"
            )
          end
          unless affected == 1
            raise Phronomy::Persistence::ConflictError,
              "stale Workflow revision for #{workflow_instance_id}"
          end
          nil
        end
      end
    end
  end
end
