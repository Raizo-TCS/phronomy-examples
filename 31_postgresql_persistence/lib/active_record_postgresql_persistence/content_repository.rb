# frozen_string_literal: true

require "digest"

module PhronomyExamples
  module Persistence
    class ActiveRecordPostgreSQL < Phronomy::Persistence
      class ContentRepository < Phronomy::ContentStore::Base
        def initialize(connection_pool:, connection: nil)
          @access = ConnectionAccess.new(
            connection_pool: connection_pool,
            connection: connection
          )
        end

        def put(bytes, canonicalization_version:)
          value = String(bytes).dup.force_encoding(Encoding::BINARY)
          content_id = "sha256:#{Digest::SHA256.hexdigest(value)}"
          hex = value.unpack1("H*")

          @access.with_write_connection do |connection|
            connection.exec_query(
              "INSERT INTO phronomy_contents " \
              "(content_id, bytes, canonicalization_version) VALUES (" \
              "#{connection.quote(content_id)}, " \
              "decode(#{connection.quote(hex)}, 'hex'), " \
              "#{Integer(canonicalization_version)}) " \
              "ON CONFLICT (content_id) DO NOTHING"
            )

            stored = fetch_on(connection, content_id)
            verify_integrity!(content_id, stored, value)
          end

          content_id
        end

        def fetch(content_id)
          value = @access.with_read_connection do |connection|
            fetch_on(connection, content_id)
          end

          unless value
            raise Phronomy::Persistence::NotFoundError,
                  "content not found: #{content_id}"
          end

          expected_id = "sha256:#{Digest::SHA256.hexdigest(value)}"
          unless expected_id == content_id
            raise Phronomy::ContentStore::IntegrityError,
                  "content digest mismatch: #{content_id}"
          end

          value
        end

        def exist?(content_id)
          @access.with_read_connection do |connection|
            !connection.select_one(
              "SELECT 1 FROM phronomy_contents " \
              "WHERE content_id = #{connection.quote(content_id)} LIMIT 1"
            ).nil?
          end
        end

        private

        def fetch_on(connection, content_id)
          row = connection.select_one(
            "SELECT encode(bytes, 'hex') AS bytes_hex " \
            "FROM phronomy_contents " \
            "WHERE content_id = #{connection.quote(content_id)}"
          )
          return nil unless row

          [row.fetch("bytes_hex")].pack("H*").force_encoding(Encoding::BINARY)
        end

        def verify_integrity!(content_id, stored, expected)
          return if stored == expected

          raise Phronomy::ContentStore::IntegrityError,
                "content ID collision or corruption: #{content_id}"
        end
      end
    end
  end
end
