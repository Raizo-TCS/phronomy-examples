# frozen_string_literal: true

module PhronomyExamples
  module Persistence
    class ActiveRecordSQLite < Phronomy::Persistence
      class TeamExecutionRepository < ConnectionAccess
        def create_active(team_execution_id:, team_id:, execution_revision:, record:)
          execution_key = String(team_execution_id)
          team_key = String(team_id)
          revision = Integer(execution_revision)
          raise Phronomy::Persistence::ConflictError, "team_execution_id must not be empty" if execution_key.empty?
          raise Phronomy::Persistence::ConflictError, "team_id must not be empty" if team_key.empty?
          raise Phronomy::Persistence::ConflictError, "execution_revision must be non-negative" if revision.negative?

          with_write_connection do |connection|
            if active_for_team_on?(connection, team_key)
              raise Phronomy::AgentBusyError, "Team already has an active execution: #{team_key}"
            end
            execute_sql(
              connection,
              "INSERT INTO phronomy_team_executions " \
              "(team_execution_id, team_id, revision, status, active, execution_json) VALUES (" \
              "#{quote_value(connection, execution_key)}, #{quote_value(connection, team_key)}, #{revision}, " \
              "#{quote_value(connection, record.fetch("status"))}, 1, " \
              "#{quote_value(connection, Codec.dump_record(record))})"
            )
          end
          record.copy
        rescue ActiveRecord::RecordNotUnique => e
          if active_for_team?(team_key)
            raise Phronomy::AgentBusyError, "Team already has an active execution: #{team_key}"
          end
          raise Phronomy::Persistence::ConflictError, e.message
        end

        def load(team_execution_id)
          row = with_read_connection do |connection|
            select_one_sql(
              connection,
              "SELECT execution_json FROM phronomy_team_executions " \
              "WHERE team_execution_id = #{quote_value(connection, team_execution_id)}"
            )
          end
          unless row
            raise Phronomy::Persistence::NotFoundError,
              "Team execution not found: #{team_execution_id}"
          end
          Codec.load_record(row.fetch("execution_json"))
        end

        def save(team_execution_id, expected_revision:, next_revision:, team_id:, active:, record:)
          expected = Integer(expected_revision)
          next_value = Integer(next_revision)
          unless next_value == expected + 1
            raise Phronomy::Persistence::ConflictError,
              "Team execution revision must advance exactly once"
          end
          unless active.equal?(true) || active.equal?(false)
            raise Phronomy::Persistence::ConflictError,
              "Team execution active metadata must be true or false"
          end

          outcome = with_write_connection do |connection|
            stored = select_one_sql(
              connection,
              "SELECT team_id FROM phronomy_team_executions " \
              "WHERE team_execution_id = #{quote_value(connection, team_execution_id)}"
            )
            next :not_found unless stored
            next :identity_conflict unless stored.fetch("team_id") == team_id.to_s
            if active && active_for_team_on?(connection, team_id, excluding_execution_id: team_execution_id)
              next :team_busy
            end

            affected = update_sql(
              connection,
              "UPDATE phronomy_team_executions SET " \
              "revision = #{next_value}, status = #{quote_value(connection, record.fetch("status"))}, " \
              "active = #{active ? 1 : 0}, execution_json = #{quote_value(connection, Codec.dump_record(record))} " \
              "WHERE team_execution_id = #{quote_value(connection, team_execution_id)} " \
              "AND revision = #{expected}"
            )
            affected == 1 ? :ok : :conflict
          end

          case outcome
          when :ok then record.copy
          when :not_found
            raise Phronomy::Persistence::NotFoundError,
              "Team execution not found: #{team_execution_id}"
          when :identity_conflict
            raise Phronomy::Persistence::ConflictError,
              "Team execution Team identity mismatch: #{team_execution_id}"
          when :team_busy
            raise Phronomy::AgentBusyError,
              "Team already has an active execution: #{team_id}"
          else
            raise Phronomy::Persistence::ConflictError,
              "stale Team execution revision for #{team_execution_id}"
          end
        end

        def list_active(team_id)
          rows = with_read_connection do |connection|
            select_all_sql(
              connection,
              "SELECT execution_json FROM phronomy_team_executions " \
              "WHERE team_id = #{quote_value(connection, team_id)} AND active = 1 " \
              "ORDER BY team_execution_id ASC"
            )
          end
          rows.map { |row| Codec.load_record(row.fetch("execution_json")) }.freeze
        end

        def list(team_id, after: nil, limit: 100)
          rows = with_read_connection do |connection|
            query = +"SELECT execution_json FROM phronomy_team_executions " \
                    "WHERE team_id = #{quote_value(connection, team_id)}"
            query << " AND team_execution_id > #{quote_value(connection, after)}" unless after.nil?
            query << " ORDER BY team_execution_id ASC"
            query << " LIMIT #{Integer(limit)}"
            select_all_sql(connection, query)
          end
          rows.map { |row| Codec.load_record(row.fetch("execution_json")) }.freeze
        end

        def delete(team_execution_id)
          with_write_connection do |connection|
            delete_sql(
              connection,
              "DELETE FROM phronomy_team_executions WHERE team_execution_id = #{quote_value(connection, team_execution_id)}"
            )
          end
          nil
        end

        def delete_for_team(team_id)
          with_write_connection do |connection|
            delete_sql(
              connection,
              "DELETE FROM phronomy_team_executions WHERE team_id = #{quote_value(connection, team_id)}"
            )
          end
          nil
        end

        def assert_idle!(team_id)
          if active_for_team?(team_id)
            raise Phronomy::AgentBusyError,
              "Team already has an active execution: #{team_id}"
          end
          true
        end

        private

        def active_for_team?(team_id)
          with_read_connection { |connection| active_for_team_on?(connection, team_id) }
        end

        def active_for_team_on?(connection, team_id, excluding_execution_id: nil)
          query = +"SELECT 1 FROM phronomy_team_executions " \
                  "WHERE team_id = #{quote_value(connection, team_id)} AND active = 1"
          if excluding_execution_id
            query << " AND team_execution_id <> #{quote_value(connection, excluding_execution_id)}"
          end
          query << " LIMIT 1"
          !select_one_sql(connection, query).nil?
        end
      end
    end
  end
end
