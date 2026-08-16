# frozen_string_literal: true

module PhronomyExamples
  module Persistence
    class ActiveRecordSQLite < Phronomy::Persistence
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

        def execute_sql(connection, sql)
          connection.execute(sql)
        end

        def update_sql(connection, sql)
          connection.update(sql)
        end

        def delete_sql(connection, sql)
          connection.delete(sql)
        end
      end
    end
  end
end
