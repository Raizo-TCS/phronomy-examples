# frozen_string_literal: true

# Example 09 intentionally consumes the concrete SQLite Persistence backend
# implemented and contract-tested by example 30. Keep the backend implementation
# authoritative there; this Rails app is only a consumer.
require Rails.root.join(
  "../30_sqlite_persistence/lib/active_record_sqlite_persistence"
).expand_path.to_s

module PhronomyStore
  class << self
    attr_reader :persistence
  end

  # The Phronomy durable tables live in the Rails primary SQLite database.
  # db/migrate/20260816180000_create_phronomy_persistence_tables.rb provisions
  # the same storage shape used by the standalone reference backend.
  @persistence =
    PhronomyExamples::Persistence::ActiveRecordSQLite.new(
      connection_pool: ActiveRecord::Base.connection_pool
    )
end
