# frozen_string_literal: true

module PhronomyExamples
  module Persistence
    class ActiveRecordPostgreSQL < Phronomy::Persistence
      class TeamRepository < ConnectionAccess
        def create(team_id:, team_revision:, record:)
          key = String(team_id)
          revision = Integer(team_revision)
          raise Phronomy::Persistence::ConflictError, "team_id must not be empty" if key.empty?
          raise Phronomy::Persistence::ConflictError, "team_revision must be non-negative" if revision.negative?

          inserted = with_write_connection do |connection|
            exec_query_sql(
              connection,
              "INSERT INTO phronomy_teams (team_id, revision, root_json) VALUES (" \
              "#{quote_value(connection, key)}, #{revision}, " \
              "#{quote_value(connection, Codec.dump_record(record))}) " \
              "ON CONFLICT (team_id) DO NOTHING RETURNING team_id"
            )
          end
          if inserted.empty?
            raise Phronomy::Persistence::ConflictError, "Team already exists: #{key}"
          end
          record.copy
        end

        def load(team_id)
          row = with_read_connection { |connection| load_row_on(connection, team_id) }
          unless row
            raise Phronomy::Persistence::NotFoundError, "Team not found: #{team_id}"
          end
          Codec.load_record(row.fetch("root_json"))
        end

        def save(team_id, expected_revision:, next_revision:, record:)
          expected = Integer(expected_revision)
          next_value = Integer(next_revision)
          unless next_value == expected + 1
            raise Phronomy::Persistence::ConflictError,
              "Team revision must advance exactly once"
          end

          outcome = with_write_connection do |connection|
            affected = update_sql(
              connection,
              "UPDATE phronomy_teams SET revision = #{next_value}, " \
              "root_json = #{quote_value(connection, Codec.dump_record(record))} " \
              "WHERE team_id = #{quote_value(connection, team_id)} " \
              "AND revision = #{expected}"
            )
            if affected == 1
              :ok
            elsif load_row_on(connection, team_id)
              :conflict
            else
              :not_found
            end
          end

          return record.copy if outcome == :ok
          if outcome == :conflict
            raise Phronomy::Persistence::ConflictError,
              "stale Team revision for #{team_id}"
          end
          raise Phronomy::Persistence::NotFoundError, "Team not found: #{team_id}"
        end

        def delete(team_id)
          with_write_connection do |connection|
            delete_sql(connection, "DELETE FROM phronomy_teams WHERE team_id = #{quote_value(connection, team_id)}")
          end
          nil
        end

        private

        def load_row_on(connection, team_id)
          select_one_sql(
            connection,
            "SELECT revision, root_json FROM phronomy_teams " \
            "WHERE team_id = #{quote_value(connection, team_id)}"
          )
        end
      end
    end
  end
end
