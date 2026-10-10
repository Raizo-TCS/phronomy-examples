# frozen_string_literal: true

require "phronomy"
require_relative "active_record/storage/backend"
require_relative "active_record/persistence_storage_mapping"

module PhronomyActiveRecord
  # Compose all domain stores over one backend/transaction boundary.
  # The application owns the pool. No schema installation or pool shutdown.
  def self.build(connection_pool:, dialect:)
    backend = Storage::Backend.new(
      connection_pool: connection_pool, dialect: dialect,
      resources: Persistence::StorageMapping.resources,
      mappings: Persistence::StorageMapping.mappings
    )
    Phronomy::PersistenceComposition.build(backend: backend)
  end
end
