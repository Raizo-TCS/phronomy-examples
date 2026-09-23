# frozen_string_literal: true

module PhronomyExamples
  module Storage
    # Immutable physical names supplied by composition, never inferred from IDs.
    class Mapping
      IDENTIFIER = /\A[a-z_][a-z0-9_]*\z/
      attr_reader :values

      def initialize(resource, values)
        required = case resource.kind
        when :records then [:table, :key, :revision, :record, :attributes, :constants, :constraints]
        when :streams then [:table, :head_table, :stream, :position, :id, :record, :head]
        when :blobs then [:table, :key, :bytes, :attributes]
        end
        raise ArgumentError, "invalid physical mapping for #{resource.id}" unless values.keys.sort == required.sort
        names = values.reject { |key, _| key == :constants }.values.flat_map { |value| value.is_a?(Hash) ? value.values : value }
        names += values.fetch(:constants, {}).keys
        unless names.all? { |name| name.is_a?(String) && IDENTIFIER.match?(name) }
          raise ArgumentError, "physical names must be SQL identifiers"
        end
        if resource.kind != :streams && values.fetch(:attributes).keys.sort != resource.attributes.keys.sort
          raise ArgumentError, "mapped attributes differ from logical schema"
        end
        if resource.kind == :records && values.fetch(:constraints).keys.sort != resource.unique.map { |c| c[:name] }.sort
          raise ArgumentError, "mapped constraints differ from logical schema"
        end
        columns = if resource.kind == :streams
          values.values_at(:stream, :position, :id, :record)
        else
          values.values_at(:key, *(resource.kind == :records ? [:revision, :record] : [:bytes])) +
            values[:attributes].values + values.fetch(:constants, {}).keys
        end
        raise ArgumentError, "mapped columns must be distinct" unless columns.uniq == columns
        @values = copy(values)
        freeze
      end

      def [](name) = values.fetch(name)
      def fetch(name, *default) = values.fetch(name, *default)

      private

      def copy(value)
        case value
        when Hash then value.to_h { |key, item| [copy(key), copy(item)] }.freeze
        when String then value.dup.freeze
        else value
        end
      end
    end
  end
end
