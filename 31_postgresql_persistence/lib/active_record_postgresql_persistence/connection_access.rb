# frozen_string_literal: true

module PhronomyExamples
  module Persistence
    class ActiveRecordPostgreSQL < Phronomy::Persistence
      class ConnectionAccess
        def initialize(connection_pool:, connection: nil)
          @connection_pool = connection_pool
          @connection = connection
        end

        def with_read_connection
          if @connection
            yield @connection
          else
            @connection_pool.with_connection { |connection| yield connection }
          end
        end

        def with_write_connection
          if @connection
            yield @connection
          else
            @connection_pool.with_connection do |connection|
              connection.transaction { yield connection }
            end
          end
        end

        protected

        def quote_value(connection, value)
          connection.quote(value)
        end

        def select_one_sql(connection, sql)
          connection.select_one(sql)
        end

        def select_all_sql(connection, sql)
          connection.select_all(sql).to_a
        end

        def exec_query_sql(connection, sql)
          connection.exec_query(sql).to_a
        end

        def execute_sql(connection, sql)
          connection.execute(sql)
        end

        def update_sql(connection, sql)
          connection.update(sql)
        end

        def delete_sql(connection, sql)
          connection.delete(sql)
        end

        # PostgreSQL's Agent row is the common per-Agent lock anchor.
        # Journal mutation, Execution admission/state mutation, idle checks, and
        # durable watermark checks all take this row before subordinate locks.
        def lock_agent_row(connection, agent_id)
          select_one_sql(
            connection,
            "SELECT agent_id FROM phronomy_agents " \
            "WHERE agent_id = #{quote_value(connection, agent_id)} " \
            "FOR UPDATE"
          )
        end

        def lock_agent_row!(connection, agent_id)
          row = lock_agent_row(connection, agent_id)
          return row if row

          raise Phronomy::Persistence::NotFoundError,
                "Agent not found: #{agent_id}"
        end

        def sql_boolean(value)
          value ? "TRUE" : "FALSE"
        end
      end
    end
  end
end
