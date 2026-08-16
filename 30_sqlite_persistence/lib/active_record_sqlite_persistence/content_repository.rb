# frozen_string_literal: true

require "digest"

module PhronomyExamples
  module Persistence
    class ActiveRecordSQLite < Phronomy::Persistence
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

          @access.with_write_connection do |connection|
            existing = connection.select_one(
              "SELECT bytes FROM phronomy_contents " \
              "WHERE content_id = #{connection.quote(content_id)}"
            )

            if existing
              verify_integrity!(content_id, existing.fetch("bytes"), value)
            else
              hex = value.unpack1("H*")
              connection.execute(
                "INSERT INTO phronomy_contents " \
                "(content_id, bytes, canonicalization_version) VALUES (" \
                "#{connection.quote(content_id)}, X'#{hex}', " \
                "#{Integer(canonicalization_version)})"
              )
            end
          end

          content_id
        rescue ActiveRecord::RecordNotUnique
          stored = fetch(content_id)
          verify_integrity!(content_id, stored, value)
          content_id
        end

        def fetch(content_id)
          row = @access.with_read_connection do |connection|
            connection.select_one(
              "SELECT bytes FROM phronomy_contents " \
              "WHERE content_id = #{connection.quote(content_id)}"
            )
          end

          unless row
            raise Phronomy::Persistence::NotFoundError,
                  "content not found: #{content_id}"
          end

          value = row.fetch("bytes").dup.force_encoding(Encoding::BINARY)
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

        def verify_integrity!(content_id, stored, expected)
          stored_value = stored.dup.force_encoding(Encoding::BINARY)
          return if stored_value == expected

          raise Phronomy::ContentStore::IntegrityError,
                "content ID collision or corruption: #{content_id}"
        end
      end
    end
  end
end
