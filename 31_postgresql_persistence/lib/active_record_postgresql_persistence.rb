# frozen_string_literal: true

require "active_record"
require "phronomy"

module PhronomyExamples
  module Persistence
    class ActiveRecordPostgreSQL < Phronomy::Persistence
      CAPABILITIES = {
        atomic_all: true,
        atomic_admission: true,
        optimistic_revision: true
      }.freeze

      attr_reader :connection_pool

      def initialize(connection_pool:)
        @connection_pool = connection_pool
        assert_postgresql_adapter!

        super(
          contents: ContentRepository.new(connection_pool: connection_pool),
          agents: AgentRepository.new(connection_pool: connection_pool),
          journals: JournalRepository.new(connection_pool: connection_pool),
          executions: ExecutionRepository.new(connection_pool: connection_pool),
          workflow_states: WorkflowStateRepository.new(connection_pool: connection_pool)
        )
      end

      def capabilities
        CAPABILITIES
      end

      def transaction
        connection_pool.with_connection do |connection|
          connection.transaction do
            yield TransactionView.build(
              persistence: self,
              connection_pool: connection_pool,
              connection: connection
            )
          end
        end
      end

      def assert_agent_watermark!(agent_id:, agent_revision:, journal_position:)
        transaction do |tx|
          tx.assert_agent_watermark!(
            agent_id: agent_id,
            agent_revision: agent_revision,
            journal_position: journal_position
          )
        end
      end

      private

      def assert_postgresql_adapter!
        connection_pool.with_connection do |connection|
          return if connection.adapter_name == "PostgreSQL"
          raise Phronomy::Persistence::UnsupportedBackendError,
            "ActiveRecordPostgreSQL requires the ActiveRecord PostgreSQL adapter; got #{connection.adapter_name.inspect}"
        end
      end
    end
  end
end

require_relative "active_record_postgresql_persistence/codec"
require_relative "active_record_postgresql_persistence/connection_access"
require_relative "active_record_postgresql_persistence/content_repository"
require_relative "active_record_postgresql_persistence/agent_repository"
require_relative "active_record_postgresql_persistence/journal_repository"
require_relative "active_record_postgresql_persistence/execution_repository"
require_relative "active_record_postgresql_persistence/workflow_state_repository"
require_relative "active_record_postgresql_persistence/transaction_view"
