# frozen_string_literal: true

require "json"
require_relative "persistence_storage_mapping"
require_relative "storage/codec"

module PhronomyExamples
  module Persistence
    # Offline export/import for both reference SQL drivers. Never used by live
    # loading. Import refuses a populated destination and preserves revisions.
    module Unit4Snapshot
      module_function

      def export(connection_pool, revision:)
        resources = StorageMapping.resources
        resources = resources.reject { |resource| %w[agent.retentions agent.cancellations].include?(resource.id) } if revision == "r8-unit3"
        result = connection_pool.with_connection do |connection|
          connection.transaction do
            resources.to_h do |resource|
              map = StorageMapping.mappings.fetch(resource.id)
              rows = connection.select_all("SELECT * FROM #{connection.quote_table_name(map.fetch(:table))}").to_a
              entries = case resource.kind
              when :records
                rows.map do |row|
                  {"key" => row.fetch(map.fetch(:key)), "revision" => Integer(row.fetch(map.fetch(:revision))),
                   "attributes" => attributes(resource, map, row), "record" => JSON.parse(row.fetch(map.fetch(:record)))}
                end.sort_by { |entry| entry.fetch("key") }
              when :blobs
                bytes_column = connection.quote_column_name(map.fetch(:bytes))
                expression = (connection.adapter_name == "PostgreSQL") ? "encode(#{bytes_column}, 'hex')" : "lower(hex(#{bytes_column}))"
                rows = connection.select_all("SELECT *, #{expression} AS migration_hex FROM #{connection.quote_table_name(map.fetch(:table))}").to_a
                rows.map { |row| {"key" => row.fetch(map.fetch(:key)), "hex" => row.fetch("migration_hex"), "attributes" => attributes(resource, map, row)} }.sort_by { |entry| entry.fetch("key") }
              when :streams
                rows.map do |row|
                  {"stream" => row.fetch(map.fetch(:stream)), "position" => Integer(row.fetch(map.fetch(:position))),
                   "id" => row.fetch(map.fetch(:id)), "record" => JSON.parse(row.fetch(map.fetch(:record)))}
                end.sort_by { |entry| [entry.fetch("stream"), entry.fetch("position")] }
              end
              value = {"kind" => resource.kind.to_s, "entries" => entries}
              if resource.kind == :streams
                heads = connection.select_all("SELECT * FROM #{connection.quote_table_name(map.fetch(:head_table))}").to_a
                value["heads"] = heads.to_h { |row| [row.fetch(map.fetch(:stream)), Integer(row.fetch(map.fetch(:head)))] }.sort.to_h
              end
              [resource.id, value]
            end
          end
        end
        {"format" => "phronomy.snapshot/1", "revision" => revision, "resources" => result}
      end

      def import(snapshot, backend:, connection_pool:)
        unless snapshot.fetch("format") == "phronomy.snapshot/1" && snapshot.fetch("revision") == "r8-unit4"
          raise ArgumentError, "only converted unit 4 snapshots can be imported"
        end
        expected = snapshot.fetch("migration").fetch("resources_sha256")
        unless Digest::SHA256.hexdigest(Phronomy::CanonicalJSON.dump(snapshot.fetch("resources"))) == expected
          raise ArgumentError, "converted snapshot was changed after validation"
        end
        resources = StorageMapping.resources
        unless snapshot.fetch("resources").keys.sort == resources.map(&:id).sort
          raise ArgumentError, "snapshot resource set mismatch"
        end
        # Both ends are offline. Locking/CAS is still provided by the normal
        # driver during import; physical table enumeration is a migration task.
        backend.transaction do |view|
          assert_empty!(connection_pool)
          ordered = resources.sort_by do |resource|
            %w[content.blobs agent.roots team.roots workflow.states handoff.states agent.retentions agent.cancellations agent.executions team.executions agent.journal].index(resource.id)
          end
          ordered.each do |resource|
            source = snapshot.fetch("resources").fetch(resource.id)
            raise ArgumentError, "resource kind mismatch: #{resource.id}" unless source.fetch("kind") == resource.kind.to_s
            entries = source.fetch("entries")
            case resource.kind
            when :blobs
              entries.each { |entry| view.blobs(resource).put_if_absent(key: entry.fetch("key"), bytes: [entry.fetch("hex")].pack("H*"), attributes: entry.fetch("attributes").transform_keys(&:to_sym)) }
            when :records
              entries.each do |entry|
                view.records(resource).insert(key: entry.fetch("key"), revision: entry.fetch("revision"),
                  attributes: entry.fetch("attributes").transform_keys(&:to_sym), record: decode(entry))
              end
            when :streams
              groups = entries.group_by { |entry| entry.fetch("stream") }
              source.fetch("heads").each do |stream, head|
                ordered_entries = groups.delete(stream) || []
                unless ordered_entries.map { |entry| entry.fetch("position") } == (1..head).to_a
                  raise ArgumentError, "non-contiguous stream: #{stream}"
                end
                view.streams(resource).append(stream: stream, expected_head: 0,
                  entries: ordered_entries.map { |entry| Phronomy::Storage::Entry::Append.new(id: entry.fetch("id"), record: decode(entry)) })
              end
              raise ArgumentError, "stream entries without a head" unless groups.empty?
            end
          end
        end
        true
      end

      # Call with a separately established connection pool after import commits.
      def verify(snapshot, connection_pool:)
        observed = export(connection_pool, revision: "r8-unit4")
        unless observed.fetch("resources") == snapshot.fetch("resources")
          raise Phronomy::Persistence::SerializationError, "independent snapshot verification failed"
        end
        true
      end

      def assert_empty!(connection_pool)
        connection_pool.with_connection do |connection|
          tables = StorageMapping.mappings.values.flat_map { |map| [map.fetch(:table), map[:head_table]] }.compact.uniq
          tables.each do |table|
            count = connection.select_value("SELECT COUNT(*) FROM #{connection.quote_table_name(table)}").to_i
            raise ArgumentError, "migration destination is not empty: #{table}" unless count.zero?
          end
        end
      end

      def decode(entry) = Phronomy::Storage::DurableRecord.new(**entry.fetch("record").transform_keys(&:to_sym))

      def attributes(resource, mapping, row)
        resource.attributes.to_h do |name, type|
          value = row.fetch(mapping.fetch(:attributes).fetch(name))
          value = ![false, 0, "0", "f", "false"].include?(value) if type == :boolean && !value.nil?
          value = Integer(value) if type == :integer && !value.nil?
          [name.to_s, value]
        end
      end
      private_class_method :assert_empty!, :decode, :attributes
    end
  end
end
