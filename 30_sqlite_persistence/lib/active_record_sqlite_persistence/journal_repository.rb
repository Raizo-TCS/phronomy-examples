# frozen_string_literal: true

module PhronomyExamples
  module Persistence
    class ActiveRecordSQLite < Phronomy::Persistence
      class JournalRepository < ConnectionAccess
        def append(agent_id, expected_position:, records:, record_ids:)
          encoded = Array(records)
          ids = Array(record_ids).map(&:to_s)
          unless encoded.length == ids.length
            raise Phronomy::Persistence::ConflictError,
              "Journal records/record_ids length mismatch"
          end
          if ids.any?(&:empty?) || ids.uniq.length != ids.length
            raise Phronomy::Persistence::ConflictError,
              "Journal record_ids must be non-empty and unique"
          end

          with_write_connection do |connection|
            ensure_head!(connection, agent_id)
            current_position = head_on(connection, agent_id)
            unless current_position == Integer(expected_position)
              raise Phronomy::Persistence::ConflictError,
                "Journal position mismatch for #{agent_id}: expected #{expected_position}, current #{current_position}"
            end
            reject_existing_record_ids!(connection, agent_id, ids)

            encoded.each_with_index do |record, index|
              execute_sql(
                connection,
                "INSERT INTO phronomy_journal_records " \
                "(agent_id, sequence, record_id, record_json) VALUES (" \
                "#{quote_value(connection, agent_id)}, " \
                "#{Integer(expected_position) + index + 1}, " \
                "#{quote_value(connection, ids.fetch(index))}, " \
                "#{quote_value(connection, Codec.dump_record(record))})"
              )
            end

            unless encoded.empty?
              next_position = Integer(expected_position) + encoded.length
              affected = update_sql(
                connection,
                "UPDATE phronomy_journal_heads SET position = #{next_position} " \
                "WHERE agent_id = #{quote_value(connection, agent_id)} " \
                "AND position = #{Integer(expected_position)}"
              )
              unless affected == 1
                raise Phronomy::Persistence::ConflictError,
                  "Journal position changed while appending for #{agent_id}"
              end
            end
          end
          encoded.map(&:copy).freeze
        rescue ActiveRecord::RecordNotUnique => e
          raise Phronomy::Persistence::ConflictError,
            "duplicate Journal identity for #{agent_id}: #{e.message}"
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
          rows.map { |row| Codec.load_record(row.fetch("record_json")) }.freeze
        end

        def head(agent_id)
          with_read_connection { |connection| head_on(connection, agent_id) }
        end

        def delete(agent_id)
          with_write_connection do |connection|
            delete_sql(connection, "DELETE FROM phronomy_journal_records WHERE agent_id = #{quote_value(connection, agent_id)}")
            delete_sql(connection, "DELETE FROM phronomy_journal_heads WHERE agent_id = #{quote_value(connection, agent_id)}")
          end
          nil
        end

        private

        def ensure_head!(connection, agent_id)
          execute_sql(
            connection,
            "INSERT OR IGNORE INTO phronomy_journal_heads (agent_id, position) " \
            "VALUES (#{quote_value(connection, agent_id)}, 0)"
          )
        end

        def head_on(connection, agent_id)
          row = select_one_sql(
            connection,
            "SELECT position FROM phronomy_journal_heads " \
            "WHERE agent_id = #{quote_value(connection, agent_id)}"
          )
          row ? Integer(row.fetch("position")) : 0
        end

        def reject_existing_record_ids!(connection, agent_id, ids)
          ids.each do |record_id|
            row = select_one_sql(
              connection,
              "SELECT 1 FROM phronomy_journal_records " \
              "WHERE agent_id = #{quote_value(connection, agent_id)} " \
              "AND record_id = #{quote_value(connection, record_id)} LIMIT 1"
            )
            next unless row
            raise Phronomy::Persistence::ConflictError,
              "duplicate Journal record_id for #{agent_id}: #{record_id}"
          end
        end
      end
    end
  end
end
