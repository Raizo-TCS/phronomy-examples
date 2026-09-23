# frozen_string_literal: true

module PhronomyExamples
  module Storage
    module Records
      private

      def read_record(connection, resource, key:, lock: false)
        map = mapping(resource)
        row = connection.select_one("SELECT * FROM #{table(connection, map[:table])} " \
          "WHERE #{column(connection, map[:key])} = #{connection.quote(key)}#{lock ? lock_suffix : ''}")
        row && record_entry(resource, map, row)
      end

      def record_entry(resource, map, row)
        Phronomy::Storage::Entry::Record.new(key: row.fetch(map[:key]), revision: Integer(row.fetch(map[:revision])),
          attributes: read_attributes(resource, map, row), record: Codec.load(row.fetch(map[:record])))
      end

      def record_values(connection, resource, entry)
        map = mapping(resource)
        values = {map[:key] => connection.quote(entry.key), map[:revision] => entry.revision.to_s,
          map[:record] => connection.quote(Codec.dump(entry.record))}
        entry.attributes.each { |name, value| values[map[:attributes].fetch(name)] = quote_attribute(connection, resource.attributes.fetch(name), value) }
        map[:constants].each { |name, value| values[name] = connection.quote(value) }
        values
      end

      def check_unique(connection, resource, entry)
        map = mapping(resource)
        resource.unique.each do |constraint|
          next if constraint[:fields].any? { |name| entry.attributes[name].nil? }
          next unless constraint[:where].all? { |name, value| entry.attributes[name] == value }
          values = entry.attributes.slice(*constraint[:fields]).merge(constraint[:where])
          predicates = attribute_predicates(connection, resource, values)
          predicates << "#{column(connection, map[:key])} <> #{connection.quote(entry.key)}"
          row = connection.select_one("SELECT 1 FROM #{table(connection, map[:table])} WHERE #{predicates.join(' AND ')} LIMIT 1")
          raise Phronomy::Storage::UniqueConstraintError.new(resource: resource, constraint: constraint[:name]) if row
        end
      end

      def insert_record(connection, resource, entry:)
        values = record_values(connection, resource, entry)
        map = mapping(resource)
        guard_record(connection, resource, key: entry.key, attributes: entry.attributes, creating: true)
        raise Phronomy::Storage::ConflictError, "duplicate record identity" if read_record(connection, resource, key: entry.key)
        check_unique(connection, resource, entry)
        inserted = insert_row(connection, map, values,
          conflict: " ON CONFLICT DO NOTHING RETURNING #{column(connection, map[:key])}")
        if inserted.empty?
          raise Phronomy::Storage::ConflictError, "duplicate record identity" if read_record(connection, resource, key: entry.key)
          check_unique(connection, resource, entry)
          raise Phronomy::Storage::ConflictError, "record insert conflicted"
        end
        Phronomy::Storage::Entry::Record.new(**entry.to_h)
      end

      def current_for_write(connection, resource, key)
        current = read_record(connection, resource, key: key)
        return nil unless current
        guard_record(connection, resource, key: key, attributes: current.attributes)
        # The stable parent lock precedes the child lock and the current revision read.
        read_record(connection, resource, key: key, lock: true)
      end

      def replace_record(connection, resource, entry:, expected_revision:, expected_attributes:)
        values = record_values(connection, resource, entry)
        current = current_for_write(connection, resource, entry.key)
        raise Phronomy::Storage::NotFoundError, "record not found: #{entry.key}" unless current
        raise Phronomy::Storage::ConflictError, "record revision conflict" unless current.revision == expected_revision
        unless expected_attributes.all? { |key, value| current.attributes[key] == value } && resource.immutable_attributes.all? { |key| current.attributes[key] == entry.attributes[key] }
          raise Phronomy::Storage::ConflictError, "record attribute precondition failed"
        end
        check_unique(connection, resource, entry)
        map = mapping(resource)
        values.delete(map[:key])
        assignments = values.map { |name, value| "#{column(connection, name)} = #{value}" }.join(", ")
        predicates = ["#{column(connection, map[:key])} = #{connection.quote(entry.key)}", "#{column(connection, map[:revision])} = #{expected_revision}"]
        predicates += attribute_predicates(connection, resource, expected_attributes.merge(current.attributes.slice(*resource.immutable_attributes)))
        affected = connection.update("UPDATE #{table(connection, map[:table])} SET #{assignments} WHERE #{predicates.join(' AND ')}")
        raise Phronomy::Storage::ConflictError, "record revision conflict" unless affected == 1
        Phronomy::Storage::Entry::Record.new(**entry.to_h)
      rescue ActiveRecord::RecordNotUnique => error
        translate_unique!(error, resource)
      end

      def translate_unique!(error, resource)
        map = mapping(resource)
        physical = if @dialect == :postgresql && error.cause.respond_to?(:result) && error.cause.result
          error.cause.result.error_field(PG::Result::PG_DIAG_CONSTRAINT_NAME)
        end
        constraint = resource.unique.find do |candidate|
          if physical
            map[:constraints].fetch(candidate[:name]) == physical
          else
            fields = candidate[:fields].map { |name| "#{map[:table]}.#{map[:attributes].fetch(name)}" }.join(', ')
            error.message.include?("UNIQUE constraint failed: #{fields}")
          end
        end
        raise error unless constraint
        raise Phronomy::Storage::UniqueConstraintError.new(resource: resource, constraint: constraint[:name])
      end

      def delete_record(connection, resource, key:, expected_revision:)
        current = current_for_write(connection, resource, key)
        unchecked = expected_revision.equal?(Phronomy::Storage::Records::UNCHECKED)
        if !unchecked && (!current || current.revision != expected_revision)
          raise Phronomy::Storage::ConflictError, "record deletion revision conflict"
        end
        return nil unless current
        map = mapping(resource)
        predicates = "#{column(connection, map[:key])} = #{connection.quote(key)}"
        predicates += " AND #{column(connection, map[:revision])} = #{expected_revision}" unless unchecked
        affected = connection.delete("DELETE FROM #{table(connection, map[:table])} WHERE #{predicates}")
        raise Phronomy::Storage::ConflictError, "record deletion revision conflict" if !unchecked && affected != 1
        nil
      end

      def scan_records(connection, resource, equals:, after:, limit:)
        map = mapping(resource)
        predicates = attribute_predicates(connection, resource, equals)
        key = column(connection, map[:key]) + binary_collation
        predicates << "#{key} > #{connection.quote(after)}" if after
        query = "SELECT * FROM #{table(connection, map[:table])} WHERE #{predicates.join(' AND ')} ORDER BY #{key} ASC"
        query += " LIMIT #{limit}" if limit
        connection.select_all(query).map { |row| record_entry(resource, map, row) }.freeze
      end

      def delete_matching_records(connection, resource, equals:)
        if resource.guard && ![:key, :stream].include?(resource.guard[:via])
          raise ArgumentError, "deletion must constrain its guard attribute" unless equals.key?(resource.guard[:via])
          guard_record(connection, resource, key: "unused", attributes: equals)
        end
        map = mapping(resource)
        predicates = attribute_predicates(connection, resource, equals)
        connection.delete("DELETE FROM #{table(connection, map[:table])} WHERE #{predicates.join(' AND ')}")
        nil
      end
    end
  end
end
