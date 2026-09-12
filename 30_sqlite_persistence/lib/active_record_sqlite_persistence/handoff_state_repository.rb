# frozen_string_literal: true

module PhronomyExamples
  module Persistence
    class ActiveRecordSQLite < Phronomy::Persistence
      class HandoffStateRepository < ConnectionAccess
        def load(main_agent_id)
          row = with_read_connection do |connection|
            select_one_sql(
              connection,
              "SELECT state_json FROM phronomy_handoff_states " \
              "WHERE main_agent_id = #{quote_value(connection, main_agent_id)}"
            )
          end
          row ? Codec.load_record(row.fetch("state_json")) : nil
        end

        def save(main_agent_id, expected_revision:, next_revision:, active_agent_id:, record:)
          expected = expected_revision.nil? ? nil : Integer(expected_revision)
          next_value = Integer(next_revision)
          expected_next = expected.nil? ? 1 : expected + 1
          unless next_value == expected_next
            raise Phronomy::Persistence::ConflictError,
              "Handoff revision must advance exactly once"
          end
          raise Phronomy::Persistence::ConflictError, "active_agent_id must not be empty" if active_agent_id.to_s.empty?

          encoded = Codec.dump_record(record)
          if expected.nil?
            with_write_connection do |connection|
              execute_sql(
                connection,
                "INSERT INTO phronomy_handoff_states " \
                "(main_agent_id, revision, active_agent_id, state_json) VALUES (" \
                "#{quote_value(connection, main_agent_id)}, #{next_value}, " \
                "#{quote_value(connection, active_agent_id)}, #{quote_value(connection, encoded)})"
              )
            end
            return record.copy
          end

          affected = with_write_connection do |connection|
            update_sql(
              connection,
              "UPDATE phronomy_handoff_states SET revision = #{next_value}, " \
              "active_agent_id = #{quote_value(connection, active_agent_id)}, " \
              "state_json = #{quote_value(connection, encoded)} " \
              "WHERE main_agent_id = #{quote_value(connection, main_agent_id)} " \
              "AND revision = #{expected}"
            )
          end
          unless affected == 1
            raise Phronomy::Persistence::ConflictError,
              "stale Handoff revision for #{main_agent_id}"
          end
          record.copy
        rescue ActiveRecord::RecordNotUnique
          raise Phronomy::Persistence::ConflictError,
            "Handoff state already exists: #{main_agent_id}"
        end

        def delete(main_agent_id, expected_revision:)
          affected = with_write_connection do |connection|
            delete_sql(
              connection,
              "DELETE FROM phronomy_handoff_states " \
              "WHERE main_agent_id = #{quote_value(connection, main_agent_id)} " \
              "AND revision = #{Integer(expected_revision)}"
            )
          end
          unless affected == 1
            raise Phronomy::Persistence::ConflictError,
              "stale Handoff revision for #{main_agent_id}"
          end
          nil
        end
      end
    end
  end
end
