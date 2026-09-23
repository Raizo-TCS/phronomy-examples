# frozen_string_literal: true

module PhronomyExamples
  module Persistence
    # Existing table/column names are a deployment contract, independent of SPI 2.
    module StorageMapping
      module_function

      def resources = Phronomy::PersistenceComposition::StorageSchema.resources

      def mappings
        {
          "agent.roots" => records("phronomy_agents", "agent_id", "root_json"),
          "team.roots" => records("phronomy_teams", "team_id", "root_json"),
          "agent.executions" => records("phronomy_executions", "execution_id", "execution_json",
            attributes: {owner: "agent_id", active: "active"}, constants: {"status" => "opaque"},
            constraints: {one_active_owner: "idx_phronomy_executions_one_active"}),
          "team.executions" => records("phronomy_team_executions", "team_execution_id", "execution_json",
            attributes: {owner: "team_id", active: "active"},
            constraints: {one_active_owner: "idx_phronomy_team_executions_one_active"}),
          "workflow.states" => records("phronomy_workflow_states", "thread_id", "snapshot_json"),
          "handoff.states" => records("phronomy_handoff_states", "main_agent_id", "state_json",
            attributes: {active_agent_id: "active_agent_id"}),
          "agent.journal" => {table: "phronomy_journal_records", head_table: "phronomy_journal_heads",
            stream: "agent_id", head: "position", position: "sequence", id: "record_id", record: "record_json"},
          "content.blobs" => {table: "phronomy_contents", key: "content_id", bytes: "bytes",
            attributes: {canonicalization_version: "canonicalization_version"}}
        }
      end

      def records(table, key, record, attributes: {}, constants: {}, constraints: {})
        {table: table, key: key, revision: "revision", record: record,
          attributes: attributes, constants: constants, constraints: constraints}
      end
      private_class_method :records
    end
  end
end
