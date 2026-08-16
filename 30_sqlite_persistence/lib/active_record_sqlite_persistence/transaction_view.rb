# frozen_string_literal: true

module PhronomyExamples
  module Persistence
    class ActiveRecordSQLite < Phronomy::Persistence
      class TransactionView
        attr_reader :contents, :agents, :journals, :executions, :workflow_states

        def initialize(connection_pool:, connection:)
          @contents = ContentRepository.new(
            connection_pool: connection_pool,
            connection: connection
          )
          @agents = AgentRepository.new(
            connection_pool: connection_pool,
            connection: connection
          )
          @journals = JournalRepository.new(
            connection_pool: connection_pool,
            connection: connection
          )
          @executions = ExecutionRepository.new(
            connection_pool: connection_pool,
            connection: connection
          )
          @workflow_states = WorkflowStateRepository.new(
            connection_pool: connection_pool,
            connection: connection
          )
        end

        def assert_agent_watermark!(agent_id:, agent_revision:, journal_position:)
          root = agents.load(agent_id)
          unless root.agent_revision == agent_revision
            raise Phronomy::Persistence::ConflictError,
                  "Agent revision watermark mismatch for #{agent_id}: " \
                  "expected #{agent_revision}, current #{root.agent_revision}"
          end

          current_position = journals.head(agent_id)
          unless current_position == journal_position
            raise Phronomy::Persistence::ConflictError,
                  "Journal position watermark mismatch for #{agent_id}: " \
                  "expected #{journal_position}, current #{current_position}"
          end

          true
        end
      end
    end
  end
end
