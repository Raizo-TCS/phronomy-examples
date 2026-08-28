# frozen_string_literal: true

module PhronomyExamples
  module Persistence
    class ActiveRecordSQLite < Phronomy::Persistence
      class TransactionView
        class Watermark < ConnectionAccess
          def assert_agent_watermark!(agent_id:, agent_revision:, journal_position:)
            with_read_connection do |connection|
              agent = select_one_sql(
                connection,
                "SELECT revision FROM phronomy_agents " \
                "WHERE agent_id = #{quote_value(connection, agent_id)}"
              )
              unless agent
                raise Phronomy::Persistence::NotFoundError,
                  "Agent not found: #{agent_id}"
              end
              actual_revision = Integer(agent.fetch("revision"))
              unless actual_revision == Integer(agent_revision)
                raise Phronomy::Persistence::ConflictError,
                  "Agent revision watermark mismatch for #{agent_id}: expected #{agent_revision}, current #{actual_revision}"
              end

              head = select_one_sql(
                connection,
                "SELECT position FROM phronomy_journal_heads " \
                "WHERE agent_id = #{quote_value(connection, agent_id)}"
              )
              actual_position = head ? Integer(head.fetch("position")) : 0
              unless actual_position == Integer(journal_position)
                raise Phronomy::Persistence::ConflictError,
                  "Journal position watermark mismatch for #{agent_id}: expected #{journal_position}, current #{actual_position}"
              end
            end
            true
          end
        end

        def self.build(persistence:, connection_pool:, connection:)
          contents = ContentRepository.new(connection_pool: connection_pool, connection: connection)
          agents = AgentRepository.new(connection_pool: connection_pool, connection: connection)
          journals = JournalRepository.new(connection_pool: connection_pool, connection: connection)
          executions = ExecutionRepository.new(connection_pool: connection_pool, connection: connection)
          workflow_states = WorkflowStateRepository.new(connection_pool: connection_pool, connection: connection)
          watermark = Watermark.new(connection_pool: connection_pool, connection: connection)

          persistence.build_transaction_view(
            contents: contents,
            agents: agents,
            journals: journals,
            executions: executions,
            workflow_states: workflow_states,
            watermark: watermark
          )
        end
      end
    end
  end
end
