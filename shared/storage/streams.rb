# frozen_string_literal: true

module PhronomyExamples
  module Storage
    module Streams
      private

      def append_stream(connection, resource, stream:, expected_head:, entries:)
        payloads = entries.map { |entry| Codec.dump(entry.record) }
        map = mapping(resource)
        guard_record(connection, resource, key: stream)
        head_map = {table: map[:head_table]}
        insert_row(connection, head_map, {map[:stream] => connection.quote(stream), map[:head] => "0"},
          conflict: " ON CONFLICT (#{column(connection, map[:stream])}) DO NOTHING")
        row = connection.select_one("SELECT #{column(connection, map[:head])} FROM #{table(connection, map[:head_table])} " \
          "WHERE #{column(connection, map[:stream])} = #{connection.quote(stream)}#{lock_suffix}")
        raise Phronomy::Storage::ConflictError, "stream head conflict" unless Integer(row.fetch(map[:head])) == expected_head
        entries.each do |entry|
          duplicate = connection.select_one("SELECT 1 FROM #{table(connection, map[:table])} WHERE " \
            "#{column(connection, map[:stream])} = #{connection.quote(stream)} AND #{column(connection, map[:id])} = #{connection.quote(entry.id)} LIMIT 1")
          raise Phronomy::Storage::ConflictError, "duplicate stream entry identity" if duplicate
        end
        entries.each_with_index do |entry, index|
          insert_row(connection, map, {map[:stream] => connection.quote(stream), map[:position] => (expected_head + index + 1).to_s,
            map[:id] => connection.quote(entry.id), map[:record] => connection.quote(payloads.fetch(index))})
        end
        unless entries.empty?
          affected = connection.update("UPDATE #{table(connection, map[:head_table])} SET #{column(connection, map[:head])} = #{expected_head + entries.length} " \
            "WHERE #{column(connection, map[:stream])} = #{connection.quote(stream)} AND #{column(connection, map[:head])} = #{expected_head}")
          raise Phronomy::Storage::ConflictError, "stream head conflict" unless affected == 1
        end
        entries.each_with_index.map { |entry, index| Phronomy::Storage::Entry::Stream.new(position: expected_head + index + 1, id: entry.id, record: entry.record) }.freeze
      end

      def read_stream(connection, resource, stream:, after:, limit:)
        map = mapping(resource)
        query = "SELECT * FROM #{table(connection, map[:table])} WHERE #{column(connection, map[:stream])} = #{connection.quote(stream)} " \
          "AND #{column(connection, map[:position])} > #{after} ORDER BY #{column(connection, map[:position])} ASC"
        query += " LIMIT #{limit}" if limit
        connection.select_all(query).map do |row|
          Phronomy::Storage::Entry::Stream.new(position: Integer(row.fetch(map[:position])), id: row.fetch(map[:id]), record: Codec.load(row.fetch(map[:record])))
        end.freeze
      end

      def stream_head(connection, resource, stream:)
        map = mapping(resource)
        row = connection.select_one("SELECT #{column(connection, map[:head])} FROM #{table(connection, map[:head_table])} WHERE #{column(connection, map[:stream])} = #{connection.quote(stream)}")
        row ? Integer(row.fetch(map[:head])) : 0
      end

      def delete_stream(connection, resource, stream:)
        guard_record(connection, resource, key: stream)
        map = mapping(resource)
        connection.select_one("SELECT #{column(connection, map[:head])} FROM #{table(connection, map[:head_table])} " \
          "WHERE #{column(connection, map[:stream])} = #{connection.quote(stream)}#{lock_suffix}")
        [map[:table], map[:head_table]].each do |name|
          connection.delete("DELETE FROM #{table(connection, name)} WHERE #{column(connection, map[:stream])} = #{connection.quote(stream)}")
        end
        nil
      end
    end
  end
end
