# frozen_string_literal: true

module PhronomyExamples
  module Persistence
    class ActiveRecordPostgreSQL < Phronomy::Persistence
      class JournalRepository < ConnectionAccess
        def append(agent_id, expected_position:, records:)
          records = Array(records)
          validate_records!(agent_id, records)
          reject_duplicate_input_ids!(records)

          with_write_connection do |connection|
            lock_agent_row!(connection, agent_id)
            ensure_head!(connection, agent_id)
            current_position = head_on(connection, agent_id, lock: true)

            unless current_position == expected_position
              raise Phronomy::Persistence::ConflictError,
                    "Journal position mismatch for #{agent_id}: " \
                    "expected #{expected_position}, current #{current_position}"
            end

            reject_existing_record_ids!(connection, agent_id, records)

            if records.empty?
              [].freeze
            else
              appended = records.each_with_index.map do |record, index|
                record.with_sequence(expected_position + index + 1)
              end

              appended.each do |record|
                execute_sql(
                  connection,
                  "INSERT INTO phronomy_journal_records " \
                  "(agent_id, sequence, record_id, record_json) VALUES (" \
                  "#{quote_value(connection, agent_id)}, #{Integer(record.sequence)}, " \
                  "#{quote_value(connection, record.record_id)}, " \
                  "#{quote_value(connection, Codec.dump_domain(record))})"
                )
              end

              affected = update_sql(
                connection,
                "UPDATE phronomy_journal_heads " \
                "SET position = #{Integer(expected_position + appended.length)} " \
                "WHERE agent_id = #{quote_value(connection, agent_id)} " \
                "AND position = #{Integer(expected_position)}"
              )

              unless affected == 1
                raise Phronomy::Persistence::ConflictError,
                      "Journal position changed while appending for #{agent_id}"
              end

              appended.freeze
            end
          end
        end

        def read(agent_id, after: nil, limit: nil)
          rows = with_read_connection do |connection|
            query = +"SELECT record_json FROM phronomy_journal_records " \
                     "WHERE agent_id = #{quote_value(connection, agent_id)}"
            query << " AND sequence > #{Integer(after)}" unless after.nil?
            query << " ORDER BY sequence ASC"
            query << " LIMIT #{Integer(limit)}" unless limit.nil?
            select_all_sql(connection, query)
          end

          rows.map { |row| Codec.load_journal_record(row.fetch("record_json")) }.freeze
        end

        def head(agent_id)
          with_read_connection { |connection| head_on(connection, agent_id) }
        end

        def delete(agent_id)
          with_write_connection do |connection|
            # If the Agent still exists, share the same lock order as append.
            lock_agent_row(connection, agent_id)

            delete_sql(
              connection,
              "DELETE FROM phronomy_journal_records " \
              "WHERE agent_id = #{quote_value(connection, agent_id)}"
            )
            delete_sql(
              connection,
              "DELETE FROM phronomy_journal_heads " \
              "WHERE agent_id = #{quote_value(connection, agent_id)}"
            )
          end
          nil
        end

        private

        def validate_records!(agent_id, records)
          mismatched = records.find { |record| record.agent_id != agent_id }
          return unless mismatched

          raise Phronomy::Persistence::ConflictError,
                "Journal record belongs to another Agent: #{mismatched.record_id}"
        end

        def reject_duplicate_input_ids!(records)
          ids = records.map(&:record_id)
          return if ids.uniq.length == ids.length

          raise Phronomy::Persistence::ConflictError,
                "duplicate record_id within one Journal append"
        end

        def reject_existing_record_ids!(connection, agent_id, records)
          records.each do |record|
            existing = select_one_sql(
              connection,
              "SELECT 1 FROM phronomy_journal_records " \
              "WHERE agent_id = #{quote_value(connection, agent_id)} " \
              "AND record_id = #{quote_value(connection, record.record_id)} LIMIT 1"
            )
            next unless existing

            raise Phronomy::Persistence::ConflictError,
                  "duplicate Journal record_id for #{agent_id}: #{record.record_id}"
          end
        end

        def ensure_head!(connection, agent_id)
          exec_query_sql(
            connection,
            "INSERT INTO phronomy_journal_heads (agent_id, position) " \
            "VALUES (#{quote_value(connection, agent_id)}, 0) " \
            "ON CONFLICT (agent_id) DO NOTHING"
          )
        end

        def head_on(connection, agent_id, lock: false)
          suffix = lock ? " FOR UPDATE" : ""
          row = select_one_sql(
            connection,
            "SELECT position FROM phronomy_journal_heads " \
            "WHERE agent_id = #{quote_value(connection, agent_id)}#{suffix}"
          )
          row ? Integer(row.fetch("position")) : 0
        end
      end
    end
  end
end
