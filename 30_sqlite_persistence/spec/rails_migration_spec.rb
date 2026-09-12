# frozen_string_literal: true

require "spec_helper"
require "phronomy/testing/persistence_contract"
require_relative "../../09_rails_chat/db/migrate/20260907000000_add_phronomy_coordination_repositories"

RSpec.describe "Example 09 coordination table upgrade" do
  include_context "coordination repository values"

  it "upgrades the five-repository schema without losing existing content or Agents" do
    persistence, pool = build_sqlite_persistence
    root = build_agent_root
    persistence.agents.create(root)
    ref = persistence.contents.put_text("existing application data")
    pool.with_connection do |connection|
      %i[phronomy_handoff_states phronomy_team_executions phronomy_teams].each { |table| connection.drop_table(table) }
      ActiveRecord::Migration.suppress_messages do
        AddPhronomyCoordinationRepositories.new.exec_migration(connection, :up)
      end
    end

    expect(persistence.contents.fetch_text(ref)).to eq("existing application data")
    expect(persistence.agents.load(root.agent_id).to_h).to eq(root.to_h)
    persistence.teams.create(coordination_team)
    persistence.team_executions.create_active(coordination_run)
    persistence.handoff_states.save(coordination_handoff.main_agent_id, expected_revision: nil, state: coordination_handoff)
    expect(persistence.team_executions.list_active(coordination_team.team_id).length).to eq(1)
    expect(persistence.handoff_states.load(coordination_handoff.main_agent_id).to_h).to eq(coordination_handoff.to_h)
    other = coordination_run.with(team_execution_id: SecureRandom.uuid, execution_revision: 0)
    expect { persistence.team_executions.create_active(other) }.to raise_error(Phronomy::AgentBusyError)
  end
end
