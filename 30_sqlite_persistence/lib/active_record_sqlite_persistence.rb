# frozen_string_literal: true

require "phronomy/active_record"
require_relative "../../shared/persistence_storage_mapping"

module PhronomyExamples
  module Persistence
    class ActiveRecordSQLite < PhronomyActiveRecord::Storage::Backend
      def initialize(connection_pool:)
        super(connection_pool: connection_pool, resources: StorageMapping.resources,
          mappings: StorageMapping.mappings, dialect: :sqlite)
      end
    end
  end
end
