# frozen_string_literal: true

module PhronomyExamples
  module Storage
    module Blobs
      private

      def put_blob(connection, resource, blob:)
        map = mapping(resource)
        hex = blob.bytes.unpack1("H*")
        bytes = @dialect == :postgresql ? "decode(#{connection.quote(hex)}, 'hex')" : "X'#{hex}'"
        values = {map[:key] => connection.quote(blob.key), map[:bytes] => bytes}
        blob.attributes.each { |name, value| values[map[:attributes].fetch(name)] = quote_attribute(connection, resource.attributes.fetch(name), value) }
        insert_row(connection, map, values, conflict: " ON CONFLICT (#{column(connection, map[:key])}) DO NOTHING")
        stored = fetch_blob(connection, resource, key: blob.key)
        raise Phronomy::Storage::BlobConflictError, "blob bytes are immutable" unless stored.bytes == blob.bytes
        stored
      end

      def fetch_blob(connection, resource, key:)
        map = mapping(resource)
        bytes = column(connection, map[:bytes])
        expression = @dialect == :postgresql ? "encode(#{bytes}, 'hex')" : "hex(#{bytes})"
        row = connection.select_one("SELECT *, #{expression} AS storage_bytes_hex FROM #{table(connection, map[:table])} WHERE #{column(connection, map[:key])} = #{connection.quote(key)}")
        raise Phronomy::Storage::NotFoundError, "blob not found: #{key}" unless row
        Phronomy::Storage::Entry::Blob.new(key: row.fetch(map[:key]), bytes: [row.fetch("storage_bytes_hex")].pack("H*"),
          attributes: read_attributes(resource, map, row))
      end

      def blob_exists(connection, resource, key:)
        map = mapping(resource)
        !connection.select_one("SELECT 1 FROM #{table(connection, map[:table])} WHERE #{column(connection, map[:key])} = #{connection.quote(key)} LIMIT 1").nil?
      end
    end
  end
end
