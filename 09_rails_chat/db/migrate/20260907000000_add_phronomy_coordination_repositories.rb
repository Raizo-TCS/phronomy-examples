# frozen_string_literal: true

class AddPhronomyCoordinationRepositories < ActiveRecord::Migration[8.1]
  def change
    create_table :phronomy_teams, id: false do |table|
      table.string :team_id, null: false
      table.integer :revision, null: false
      table.text :root_json, null: false
    end
    add_index :phronomy_teams, :team_id, unique: true,
      name: "idx_phronomy_teams_team_id"

    create_table :phronomy_team_executions, id: false do |table|
      table.string :team_execution_id, null: false
      table.string :team_id, null: false
      table.integer :revision, null: false
      table.boolean :active, null: false
      table.text :execution_json, null: false
    end
    add_index :phronomy_team_executions, :team_execution_id, unique: true,
      name: "idx_phronomy_team_executions_team_execution_id"
    add_index :phronomy_team_executions, :team_id, unique: true,
      where: "active = 1", name: "idx_phronomy_team_executions_one_active"

    create_table :phronomy_handoff_states, id: false do |table|
      table.string :main_agent_id, null: false
      table.string :active_agent_id, null: false
      table.integer :revision, null: false
      table.text :state_json, null: false
    end
    add_index :phronomy_handoff_states, :main_agent_id, unique: true,
      name: "idx_phronomy_handoff_states_main_agent_id"
  end
end
