# frozen_string_literal: true

require_relative "schema_v1/sqlite"
require_relative "schema_v1/postgresql"

module PhronomyActiveRecord
  # Versioned, explicit DDL. Keep v1 assets unchanged in future releases.
  module SchemaV1
    class ConnectionScope
      def initialize(connection)
        @connection = connection
      end

      def with_connection
        yield @connection
      end
    end
    private_constant :ConnectionScope

    def self.install!(connection:)
      schema = case connection.adapter_name
      when "SQLite" then Persistence::SQLiteSchema
      when "PostgreSQL" then Persistence::PostgreSQLSchema
      else
        raise Phronomy::Storage::UnsupportedBackendError, "unsupported ActiveRecord adapter"
      end
      schema.apply!(ConnectionScope.new(connection))
    end
  end
end
