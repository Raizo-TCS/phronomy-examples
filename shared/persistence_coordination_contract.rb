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
    persistence.teams.create(coordination_team)
    second = coordination_run.with(team_execution_id: SecureRandom.uuid, execution_revision: 0)
    results = run_concurrently(
      -> { persistence.team_executions.create_active(coordination_run) },
      -> { persistence.team_executions.create_active(second) }
    )
    expect_one_writer(results, Phronomy::AgentBusyError)
    winner = persistence.team_executions.list_active(coordination_team.team_id).fetch(0)
    expect { persistence.team_executions.create_active(winner) }.to raise_error(Phronomy::Persistence::ConflictError)
    expect { persistence.team_executions.assert_idle!(coordination_team.team_id) }.to raise_error(Phronomy::AgentBusyError)
  end

  it "allows one Team root CAS writer" do
    persistence.teams.create(coordination_team)
    updated = coordination_team.with(lifecycle_status: "active")
    expect_one_writer(run_concurrently(
      -> { persistence.teams.save(coordination_team.team_id, expected_revision: 0, root: updated) },
      -> { persistence.teams.save(coordination_team.team_id, expected_revision: 0, root: updated) }
    ), Phronomy::Persistence::ConflictError)
  end

  it "allows one Team terminal CAS writer and rejects terminal reactivation" do
    persistence.teams.create(coordination_team)
    persistence.team_executions.create_active(coordination_run)
    completed = coordination_run.with(status: "completed", phase: "completed")
    expect_one_writer(run_concurrently(
      -> { persistence.team_executions.save(completed.team_execution_id, expected_revision: 0, execution: completed) },
      -> { persistence.team_executions.save(completed.team_execution_id, expected_revision: 0, execution: completed) }
    ), Phronomy::Persistence::ConflictError)
    expect(persistence.team_executions.assert_idle!(coordination_team.team_id)).to be(true)
    expect do
      persistence.team_executions.save(completed.team_execution_id, expected_revision: 1,
        execution: completed.with(status: "active", phase: "coordinator"))
    end.to raise_error(Phronomy::Persistence::ConflictError)
  end

  it "allows one initial Handoff writer and one later CAS writer" do
    id = coordination_handoff.main_agent_id
    expect_one_writer(run_concurrently(
      -> { persistence.handoff_states.save(id, expected_revision: nil, state: coordination_handoff) },
      -> { persistence.handoff_states.save(id, expected_revision: nil, state: coordination_handoff) }
    ), Phronomy::Persistence::ConflictError)
    changed = coordination_handoff.with(phase: "stable")
    expect_one_writer(run_concurrently(
      -> { persistence.handoff_states.save(id, expected_revision: 1, state: changed) },
      -> { persistence.handoff_states.save(id, expected_revision: 1, state: changed) }
    ), Phronomy::Persistence::ConflictError)
    expect { persistence.handoff_states.delete(id, expected_revision: 1) }.to raise_error(Phronomy::Persistence::ConflictError)
    expect(persistence.handoff_states.load(id).handoff_revision).to eq(2)
    persistence.handoff_states.delete(id, expected_revision: 2)
    expect(persistence.handoff_states.load(id)).to be_nil
  end

  it "lists completed Agent executions by owner with deterministic cursor pagination" do
    root = build_agent_root
    persistence.agents.create(root)
    ids = ["execution-z'quoted", "execution-a"]
    ids.each do |id|
      run = build_execution(root).with(execution_id: id, execution_revision: 0, status: :active)
      persistence.executions.create_active(run)
      persistence.executions.save(id, expected_revision: 0, execution: run.with(status: :completed, phase: :completed))
    end
    expect(persistence.executions.list(root.agent_id, limit: 1).map(&:execution_id)).to eq(ids.sort.first(1))
    expect(persistence.executions.list(root.agent_id, after: ids.sort.first).map(&:execution_id)).to eq(ids.sort.last(1))
    expect(persistence.executions.list("another owner")).to be_empty
  end

  it "retains all three coordination repositories after disconnecting the pool" do
    persistence.teams.create(coordination_team)
    persistence.team_executions.create_active(coordination_run)
    persistence.handoff_states.save(coordination_handoff.main_agent_id, expected_revision: nil, state: coordination_handoff)
    persistence.connection_pool.disconnect!
    restored = persistence.class.new(connection_pool: persistence.connection_pool)
    expect(restored.teams.load(coordination_team.team_id).to_h).to eq(coordination_team.to_h)
    expect(restored.team_executions.load(coordination_run.team_execution_id).to_h).to eq(coordination_run.to_h)
    expect(restored.handoff_states.load(coordination_handoff.main_agent_id).to_h).to eq(coordination_handoff.to_h)
  end

  it "rolls back Team, Team execution and Handoff writes together" do
    rollback_error = Class.new(StandardError)
    expect do
      persistence.transaction do |tx|
        tx.teams.create(coordination_team)
        tx.team_executions.create_active(coordination_run)
        tx.handoff_states.save(coordination_handoff.main_agent_id, expected_revision: nil, state: coordination_handoff)
        raise rollback_error, "rollback coordination writes"
      end
    end.to raise_error(rollback_error)
    expect { persistence.teams.load(coordination_team.team_id) }.to raise_error(Phronomy::Persistence::NotFoundError)
    expect { persistence.team_executions.load(coordination_run.team_execution_id) }.to raise_error(Phronomy::Persistence::NotFoundError)
    expect(persistence.handoff_states.load(coordination_handoff.main_agent_id)).to be_nil
  end

  it "can continue the transaction after handling duplicate coordination records" do
    persistence.teams.create(coordination_team)
    persistence.team_executions.create_active(coordination_run)
    persistence.handoff_states.save(coordination_handoff.main_agent_id, expected_revision: nil, state: coordination_handoff)
    content_id = nil
    persistence.transaction do |tx|
      expect { tx.teams.create(coordination_team) }.to raise_error(Phronomy::Persistence::ConflictError)
      expect { tx.team_executions.create_active(coordination_run) }.to raise_error(Phronomy::Persistence::ConflictError)
      expect do
        tx.handoff_states.save(coordination_handoff.main_agent_id, expected_revision: nil, state: coordination_handoff)
      end.to raise_error(Phronomy::Persistence::ConflictError)
      content_id = tx.contents.put_text("write after handled conflicts")
    end
    expect(persistence.contents.fetch_text(content_id)).to eq("write after handled conflicts")
  end
end
