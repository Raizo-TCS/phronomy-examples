# frozen_string_literal: true

require "phronomy/testing/persistence_contract"

# Application-side SQL/concurrency regressions supplement the authoritative
# contract shipped by Phronomy. Both adapters execute exactly these assertions.
RSpec.shared_examples "a SQL coordination backend" do
  include_context "coordination repository values"

  def expect_one_writer(results, error_class)
    expect(results.count { |kind, _| kind == :ok }).to eq(1)
    errors = results.filter_map { |kind, value| value if kind == :error }
    expect(errors.length).to eq(1)
    expect(errors.first).to be_a(error_class)
  end

  it "admits only one concurrent Team run and preserves duplicate identity errors" do
    stores.team.teams.create(coordination_team)
    second = coordination_run.with(team_execution_id: SecureRandom.uuid, execution_revision: 0)
    results = run_concurrently(
      -> { stores.team.team_executions.create_active(coordination_run) },
      -> { stores.team.team_executions.create_active(second) }
    )
    expect_one_writer(results, Phronomy::AgentBusyError)
    winner = stores.team.team_executions.list_active(coordination_team.team_id).fetch(0)
    expect { stores.team.team_executions.create_active(winner) }.to raise_error(Phronomy::Persistence::ConflictError) do |error|
      expect(error.cause).to be_a(Phronomy::Storage::ConflictError)
    end
    expect { stores.team.team_executions.assert_idle!(coordination_team.team_id) }.to raise_error(Phronomy::AgentBusyError)
  end

  it "allows one Team root CAS writer" do
    stores.team.teams.create(coordination_team)
    updated = coordination_team.with(lifecycle_status: "active")
    expect_one_writer(run_concurrently(
      -> { stores.team.teams.save(coordination_team.team_id, expected_revision: 0, root: updated) },
      -> { stores.team.teams.save(coordination_team.team_id, expected_revision: 0, root: updated) }
    ), Phronomy::Persistence::ConflictError)
  end

  it "allows one Team terminal CAS writer and rejects terminal reactivation" do
    stores.team.teams.create(coordination_team)
    stores.team.team_executions.create_active(coordination_run)
    completed = coordination_run.with(status: "completed", phase: "completed")
    expect_one_writer(run_concurrently(
      -> { stores.team.team_executions.save(completed.team_execution_id, expected_revision: 0, execution: completed) },
      -> { stores.team.team_executions.save(completed.team_execution_id, expected_revision: 0, execution: completed) }
    ), Phronomy::Persistence::ConflictError)
    expect(stores.team.team_executions.assert_idle!(coordination_team.team_id)).to be(true)
    expect do
      stores.team.team_executions.save(completed.team_execution_id, expected_revision: 1,
        execution: completed.with(status: "active", phase: "coordinator"))
    end.to raise_error(Phronomy::Persistence::ConflictError)
  end

  it "allows one initial Handoff writer and one later CAS writer" do
    id = coordination_handoff.main_agent_id
    expect_one_writer(run_concurrently(
      -> { stores.agent.handoff_states.save(id, expected_revision: nil, state: coordination_handoff) },
      -> { stores.agent.handoff_states.save(id, expected_revision: nil, state: coordination_handoff) }
    ), Phronomy::Persistence::ConflictError)
    changed = coordination_handoff.with(phase: "stable")
    expect_one_writer(run_concurrently(
      -> { stores.agent.handoff_states.save(id, expected_revision: 1, state: changed) },
      -> { stores.agent.handoff_states.save(id, expected_revision: 1, state: changed) }
    ), Phronomy::Persistence::ConflictError)
    expect { stores.agent.handoff_states.delete(id, expected_revision: 1) }.to raise_error(Phronomy::Persistence::ConflictError)
    expect(stores.agent.handoff_states.load(id).handoff_revision).to eq(2)
    stores.agent.handoff_states.delete(id, expected_revision: 2)
    expect(stores.agent.handoff_states.load(id)).to be_nil
  end

  it "lists completed Agent executions by owner with deterministic cursor pagination" do
    root = build_agent_root
    stores.agent.agents.create(root)
    ids = ["execution-z'quoted", "execution-a"]
    ids.each do |id|
      run = build_execution(root).with(execution_id: id, execution_revision: 0, status: :active)
      stores.agent.executions.create_active(run)
      stores.agent.executions.save(id, expected_revision: 0, execution: run.with(status: :completed, phase: :completed))
    end
    expect(stores.agent.executions.list(root.agent_id, limit: 1).map(&:execution_id)).to eq(ids.sort.first(1))
    expect(stores.agent.executions.list(root.agent_id, after: ids.sort.first).map(&:execution_id)).to eq(ids.sort.last(1))
    expect(stores.agent.executions.list("another owner")).to be_empty
  end

  it "retains all three coordination repositories after disconnecting the pool" do
    stores.team.teams.create(coordination_team)
    stores.team.team_executions.create_active(coordination_run)
    stores.agent.handoff_states.save(coordination_handoff.main_agent_id, expected_revision: nil, state: coordination_handoff)
    stores.coordinator.backend.connection_pool.disconnect!
    restored = Phronomy::PersistenceComposition.build(backend: stores.coordinator.backend.class.new(connection_pool: stores.coordinator.backend.connection_pool))
    expect(restored.team.teams.load(coordination_team.team_id).to_h).to eq(coordination_team.to_h)
    expect(restored.team.team_executions.load(coordination_run.team_execution_id).to_h).to eq(coordination_run.to_h)
    expect(restored.agent.handoff_states.load(coordination_handoff.main_agent_id).to_h).to eq(coordination_handoff.to_h)
  end

  it "rolls back Team, Team execution and Handoff writes together" do
    rollback_error = Class.new(StandardError)
    expect do
      stores.team.transaction do |tx, scope|
        tx.teams.create(coordination_team)
        tx.team_executions.create_active(coordination_run)
        stores.agent.participate(scope) do |agent|
          agent.handoff_states.save(coordination_handoff.main_agent_id, expected_revision: nil, state: coordination_handoff)
        end
        raise rollback_error, "rollback coordination writes"
      end
    end.to raise_error(rollback_error)
    expect { stores.team.teams.load(coordination_team.team_id) }.to raise_error(Phronomy::Persistence::NotFoundError)
    expect { stores.team.team_executions.load(coordination_run.team_execution_id) }.to raise_error(Phronomy::Persistence::NotFoundError)
    expect(stores.agent.handoff_states.load(coordination_handoff.main_agent_id)).to be_nil
  end

  it "can continue the outer transaction after rolling back duplicate-record savepoints" do
    stores.team.teams.create(coordination_team)
    stores.team.team_executions.create_active(coordination_run)
    stores.agent.handoff_states.save(coordination_handoff.main_agent_id, expected_revision: nil, state: coordination_handoff)
    content_id = nil
    stores.team.transaction do |tx, scope|
      expect { stores.team.transaction { |inner| inner.teams.create(coordination_team) } }.to raise_error(Phronomy::Persistence::ConflictError)
      expect { stores.team.transaction { |inner| inner.team_executions.create_active(coordination_run) } }.to raise_error(Phronomy::Persistence::ConflictError)
      expect do
        stores.agent.transaction { |inner| inner.handoff_states.save(coordination_handoff.main_agent_id, expected_revision: nil, state: coordination_handoff) }
      end.to raise_error(Phronomy::Persistence::ConflictError)
      content_id = tx.contents.put_text("write after handled conflicts")
    end
    expect(stores.agent.contents.fetch_text(content_id)).to eq("write after handled conflicts")
  end
end
