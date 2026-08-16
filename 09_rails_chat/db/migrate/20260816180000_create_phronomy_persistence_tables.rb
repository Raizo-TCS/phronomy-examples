# frozen_string_literal: true

class CreatePhronomyPersistenceTables < ActiveRecord::Migration[8.1]
  def change
    create_table :phronomy_contents, id: false do |table|
      table.string :content_id, null: false
      table.binary :bytes, null: false
      table.integer :canonicalization_version, null: false
    end
    add_index :phronomy_contents,
              :content_id,
              unique: true,
              name: "idx_phronomy_contents_content_id"

    create_table :phronomy_agents, id: false do |table|
      table.string :agent_id, null: false
      table.integer :revision, null: false
      table.text :root_json, null: false
    end
    add_index :phronomy_agents,
              :agent_id,
              unique: true,
              name: "idx_phronomy_agents_agent_id"

    create_table :phronomy_journal_heads, id: false do |table|
      table.string :agent_id, null: false
      table.integer :position, null: false
    end
    add_index :phronomy_journal_heads,
              :agent_id,
              unique: true,
              name: "idx_phronomy_journal_heads_agent_id"

    create_table :phronomy_journal_records, id: false do |table|
      table.string :agent_id, null: false
      table.integer :sequence, null: false
      table.string :record_id, null: false
      table.text :record_json, null: false
    end
    add_index :phronomy_journal_records,
              %i[agent_id sequence],
              unique: true,
              name: "idx_phronomy_journal_records_sequence"
    add_index :phronomy_journal_records,
              %i[agent_id record_id],
              unique: true,
              name: "idx_phronomy_journal_records_record_id"

    create_table :phronomy_executions, id: false do |table|
      table.string :execution_id, null: false
      table.string :agent_id, null: false
      table.integer :revision, null: false
      table.string :status, null: false
      table.boolean :active, null: false
      table.text :execution_json, null: false
    end
    add_index :phronomy_executions,
              :execution_id,
              unique: true,
              name: "idx_phronomy_executions_execution_id"
    add_index :phronomy_executions,
              :agent_id,
              unique: true,
              where: "active = 1",
              name: "idx_phronomy_executions_one_active"

    create_table :phronomy_workflow_states, id: false do |table|
      table.string :thread_id, null: false
      table.integer :revision, null: false
      table.text :snapshot_json, null: false
    end
    add_index :phronomy_workflow_states,
              :thread_id,
              unique: true,
              name: "idx_phronomy_workflow_states_thread_id"
  end
end
