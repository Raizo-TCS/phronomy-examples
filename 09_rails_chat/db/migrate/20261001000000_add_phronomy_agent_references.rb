# frozen_string_literal: true

# Provisioning only. Existing execution 0.1 data requires the explicit offline
# unit 4 exporter/converter/importer before starting the new application runtime.
class AddPhronomyAgentReferences < ActiveRecord::Migration[8.1]
  def change
    create_table :phronomy_agent_retentions, id: false do |table|
      table.string :retention_id, null: false
      table.string :agent_id, null: false
      table.string :owner_key, null: false
      table.integer :revision, null: false
      table.text :retention_json, null: false
    end
    add_index :phronomy_agent_retentions, :retention_id, unique: true, name: "idx_phronomy_agent_retentions_id"
    add_index :phronomy_agent_retentions, :agent_id
    add_index :phronomy_agent_retentions, :owner_key

    create_table :phronomy_agent_cancellations, id: false do |table|
      table.string :execution_id, null: false
      table.string :agent_id, null: false
      table.integer :revision, null: false
      table.text :cancellation_json, null: false
    end
    add_index :phronomy_agent_cancellations, :execution_id, unique: true, name: "idx_phronomy_agent_cancellations_id"
    add_index :phronomy_agent_cancellations, :agent_id
  end
end
