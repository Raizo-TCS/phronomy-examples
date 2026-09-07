# frozen_string_literal: true

module PhronomyExamples
  module Persistence
    class ActiveRecordPostgreSQL < Phronomy::Persistence
      class TeamExecutionRepository < ConnectionAccess
        def create_active(team_execution_id:, team_id:, execution_revision:, record:)
          execution_key = String(team_execution_id)
          team_key = String(team_id)
          revision = Integer(execution_revision)
          raise Phronomy::Persistence::ConflictError, "team_execution_id must not be empty" if execution_key.empty?
          raise Phronomy::Persistence::ConflictError, "team_id must not be empty" if team_key.empty?
          raise Phronomy::Persistence::ConflictError, "execution_revision must be non-negative" if revision.negative?

          with_write_connection do |connection|
            lock_team_row!(connection, team_key)
            if execution_exists_on?(connection, execution_key)
              raise Phronomy::Persistence::ConflictError,
                "Execution already exists: #{execution_key}"
            end
            if active_for_team_on?(connection, team_key)
              raise Phronomy::AgentBusyError,
                "Team already has an active execution: #{team_key}"
            end

            inserted = exec_query_sql(
              connection,
              "INSERT INTO phronomy_team_executions " \
              "(team_execution_id, team_id, revision, active, execution_json) VALUES (" \
              "#{quote_value(connection, execution_key)}, " \
              "#{quote_value(connection, team_key)}, #{revision}, TRUE, " \
              "#{quote_value(connection, Codec.dump_record(record))}) " \
              "ON CONFLICT DO NOTHING RETURNING team_execution_id"
            )
            if inserted.empty?
              if execution_exists_on?(connection, execution_key)
                raise Phronomy::Persistence::ConflictError,
                  "Execution already exists: #{execution_key}"
              end
              if active_for_team_on?(connection, team_key)
                raise Phronomy::AgentBusyError,
                  "Team already has an active execution: #{team_key}"
              end
              raise Phronomy::Persistence::ConflictError,
                "Execution admission constraint conflict: #{execution_key}"
            end
          end
          record.copy
        end

        def load(team_execution_id)
          row = with_read_connection { |connection| execution_row_on(connection, team_execution_id) }
          unless row
            raise Phronomy::Persistence::NotFoundError,
              "Execution not found: #{team_execution_id}"
          end
          Codec.load_record(row.fetch("execution_json"))
        end

        def save(team_execution_id, expected_revision:, next_revision:, team_id:, active:, record:)
          expected = Integer(expected_revision)
          next_value = Integer(next_revision)
          unless next_value == expected + 1
            raise Phronomy::Persistence::ConflictError,
              "Execution revision must advance exactly once"
          end
          unless active.equal?(true) || active.equal?(false)
            raise Phronomy::Persistence::ConflictError,
              "Execution active metadata must be true or false"
          end

          outcome = with_write_connection do |connection|
            stored = execution_row_on(connection, team_execution_id)
            next :not_found unless stored
            stored_team_id = stored.fetch("team_id")
            lock_team_row!(connection, stored_team_id)
            stored = execution_row_on(connection, team_execution_id)
            next :not_found unless stored
            next :identity_conflict unless stored.fetch("team_id") == team_id.to_s
            if active && !ActiveRecord::Type::Boolean.new.cast(stored.fetch("active"))
              raise Phronomy::Persistence::ConflictError, "A terminal Team execution cannot become active"
            end
            if active && active_for_team_on?(connection, team_id, excluding_team_execution_id: team_execution_id)
              next :agent_busy
            end

            affected = update_sql(
              connection,
              "UPDATE phronomy_team_executions SET revision = #{next_value}, " \
              "active = #{sql_boolean(active)}, " \
              "execution_json = #{quote_value(connection, Codec.dump_record(record))} " \
              "WHERE team_execution_id = #{quote_value(connection, team_execution_id)} " \
              "AND revision = #{expected}"
            )
            if affected == 1
              :ok
            elsif execution_row_on(connection, team_execution_id)
              :conflict
            else
              :not_found
            end
          end

          case outcome
          when :ok then record.copy
          when :agent_busy
            raise Phronomy::AgentBusyError,
              "Team already has an active execution: #{team_id}"
          when :identity_conflict
            raise Phronomy::Persistence::ConflictError,
              "Execution Team identity mismatch for #{team_execution_id}"
          when :conflict
            raise Phronomy::Persistence::ConflictError,
              "stale Execution revision for #{team_execution_id}"
          else
            raise Phronomy::Persistence::NotFoundError,
              "Execution not found: #{team_execution_id}"
          end
        end

        def list_active(team_id)
          rows = with_read_connection do |connection|
            select_all_sql(
              connection,
              "SELECT execution_json FROM phronomy_team_executions " \
              "WHERE team_id = #{quote_value(connection, team_id)} " \
              "AND active IS TRUE ORDER BY team_execution_id ASC"
            )
          end
          rows.map { |row| Codec.load_record(row.fetch("execution_json")) }.freeze
        end

        def list(team_id, after: nil, limit: 100)
          raise ArgumentError, "limit must be a positive Integer" unless limit.is_a?(Integer) && limit.positive?

          rows = with_read_connection do |connection|
            query = +"SELECT execution_json FROM phronomy_team_executions " \
                     "WHERE team_id = #{quote_value(connection, team_id)}"
            query << " AND team_execution_id > #{quote_value(connection, after)}" if after
            query << " ORDER BY team_execution_id ASC LIMIT #{limit}"
            select_all_sql(connection, query)
          end
          rows.map { |row| Codec.load_record(row.fetch("execution_json")) }.freeze
        end

        def assert_idle!(team_id)
          busy = with_write_connection do |connection|
            lock_team_row!(connection, team_id)
            active_for_team_on?(connection, team_id)
          end
          if busy
            raise Phronomy::AgentBusyError,
              "Team already has an active execution: #{team_id}"
          end
          true
        end

        def delete(team_execution_id)
          with_write_connection do |connection|
            row = execution_row_on(connection, team_execution_id)
            if row
              lock_team_row(connection, row.fetch("team_id"))
              delete_sql(connection, "DELETE FROM phronomy_team_executions WHERE team_execution_id = #{quote_value(connection, team_execution_id)}")
            end
          end
          nil
        end

        def delete_for_team(team_id)
          with_write_connection do |connection|
            lock_team_row(connection, team_id)
            delete_sql(connection, "DELETE FROM phronomy_team_executions WHERE team_id = #{quote_value(connection, team_id)}")
          end
          nil
        end

        private

        def execution_exists_on?(connection, team_execution_id)
          !select_one_sql(
            connection,
            "SELECT 1 FROM phronomy_team_executions WHERE team_execution_id = #{quote_value(connection, team_execution_id)} LIMIT 1"
          ).nil?
        end

        def execution_row_on(connection, team_execution_id)
          select_one_sql(
            connection,
            "SELECT team_id, revision, active, execution_json FROM phronomy_team_executions " \
            "WHERE team_execution_id = #{quote_value(connection, team_execution_id)}"
          )
        end

        def active_for_team_on?(connection, team_id, excluding_team_execution_id: nil)
          query = +"SELECT 1 FROM phronomy_team_executions " \
                   "WHERE team_id = #{quote_value(connection, team_id)} AND active IS TRUE"
          if excluding_team_execution_id
            query << " AND team_execution_id <> #{quote_value(connection, excluding_team_execution_id)}"
          end
          query << " LIMIT 1"
          !select_one_sql(connection, query).nil?
        end
      end
    end
  end
end
