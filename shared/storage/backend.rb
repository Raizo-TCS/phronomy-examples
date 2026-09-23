# frozen_string_literal: true

require "active_record"
require "phronomy"
require_relative "codec"
require_relative "mapping"
require_relative "records"
require_relative "streams"
require_relative "blobs"

module PhronomyExamples
  module Storage
    # Neutral SQL primitives; domain composition supplies resources and mappings.
    class Backend < Phronomy::Storage::Backend
      include Records
      include Streams
      include Blobs
      attr_reader :connection_pool

      def initialize(connection_pool:, resources:, mappings:, dialect:)
        @connection_pool, @dialect = connection_pool, dialect
        expected = {sqlite: "SQLite", postgresql: "PostgreSQL"}.fetch(dialect)
        connection_pool.with_connection do |connection|
          unless connection.adapter_name == expected
            raise Phronomy::Storage::UnsupportedBackendError, "backend requires the ActiveRecord #{expected} adapter"
          end
        end
        super(resources: resources)
        unless mappings.keys.sort == self.resources.keys.sort
          raise ArgumentError, "every declared resource needs exactly one physical mapping"
        end
        @mappings = self.resources.to_h { |id, resource| [id, Mapping.new(resource, mappings.fetch(id))] }.freeze
      end

      def capabilities = REQUIRED_CAPABILITIES

      private

      def storage_transaction
        connection_pool.with_connection do |connection|
          rollback_error = nil
          result = connection.transaction(requires_new: true) do
            yield connection
          rescue ActiveRecord::Rollback => error
            rollback_error = error
            raise
          end
          raise rollback_error if rollback_error
          result
        end
      end

      def mapping(resource) = @mappings.fetch(resource.id)
      def column(connection, name) = connection.quote_column_name(name)
      def table(connection, name) = connection.quote_table_name(name)
      def lock_suffix = @dialect == :postgresql ? " FOR UPDATE" : ""
      def binary_collation = @dialect == :postgresql ? ' COLLATE "C"' : " COLLATE BINARY"

      def quote_attribute(connection, type, value)
        value = value ? 1 : 0 if @dialect == :sqlite && [:boolean, :nullable_boolean].include?(type) && !value.nil?
        connection.quote(value)
      end

      def attribute_predicates(connection, resource, values)
        map = mapping(resource)
        values.map do |name, value|
          field = column(connection, map[:attributes].fetch(name))
          value.nil? ? "#{field} IS NULL" : "#{field} = #{quote_attribute(connection, resource.attributes.fetch(name), value)}"
        end
      end

      def lock_guard(connection, resource, key:)
        map = mapping(resource)
        row = connection.select_one("SELECT #{column(connection, map[:key])} FROM #{table(connection, map[:table])} " \
          "WHERE #{column(connection, map[:key])} = #{connection.quote(key)}#{lock_suffix}")
        raise Phronomy::Storage::NotFoundError, "guard record not found: #{resource.id}/#{key}" unless row
        true
      end

      def guard_record(connection, resource, key:, attributes: {}, creating: false)
        guard = resource.guard
        return unless guard
        anchor = resources.fetch(guard.fetch(:resource))
        return if creating && anchor.equal?(resource) && guard[:via] == :key
        guard_key = [:key, :stream].include?(guard[:via]) ? key : attributes.fetch(guard[:via])
        lock_guard(connection, anchor, key: guard_key)
      end

      def insert_row(connection, map, values, conflict: nil)
        fields = values.keys.map { |key| column(connection, key) }.join(", ")
        query = "INSERT INTO #{table(connection, map[:table])} (#{fields}) VALUES (#{values.values.join(', ')})"
        query += conflict if conflict
        connection.exec_query(query)
      end

      def read_attributes(resource, map, row)
        values = resource.attributes.to_h do |name, type|
          value = row.fetch(map[:attributes].fetch(name))
          if [:boolean, :nullable_boolean].include?(type) && !value.nil?
            raise Phronomy::Storage::SerializationError, "invalid stored boolean" unless [true, false, 1, 0].include?(value)
            value = value == true || value == 1
          end
          value = Integer(value) if [:integer, :nullable_integer].include?(type) && !value.nil?
          [name, value]
        end
        resource.validate_attributes(values)
      rescue ArgumentError, EncodingError => error
        raise Phronomy::Storage::SerializationError, error.message
      end
    end
  end
end
