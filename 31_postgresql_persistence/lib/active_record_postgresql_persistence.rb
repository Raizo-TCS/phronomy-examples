# frozen_string_literal: true

require_relative "../../shared/storage/backend"
require_relative "../../shared/persistence_storage_mapping"

module PhronomyExamples
  module Persistence
    class ActiveRecordPostgreSQL < PhronomyExamples::Storage::Backend
      def initialize(connection_pool:)
        super(connection_pool: connection_pool, resources: StorageMapping.resources,
          mappings: StorageMapping.mappings, dialect: :postgresql)
      end
    end
  end
end
