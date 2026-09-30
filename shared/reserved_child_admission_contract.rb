# frozen_string_literal: true

require "phronomy/testing/persistence_contract"

RSpec.shared_context "reserved child stores" do
  include_context "coordination repository values"
  let(:child_root) { build_agent_root(prefix: "reserved-child") }
  let(:child_execution_id) { "reserved-child-run" }
  let(:reservation_owner) do
    {"kind" => "team", "team_id" => coordination_team.team_id,
     "team_execution_id" => coordination_run.team_execution_id, "slot" => "coordinator"}
  end
  let(:reserved_run) do
    coordination_run.with(execution_revision: 0,
      coordinator: {"agent_id" => child_root.agent_id, "execution_id" => child_execution_id})
  end

  def new_child_admission
    Phronomy::Agent::Admission.new(persistence: stores.agent, root: child_root,
      input: "reserved input", config: {phronomy_reserved_execution_id: child_execution_id,
                                       phronomy_coordination: reservation_owner}, preparation_metadata: {})
  end

  def admit_reserved_child(admission = new_child_admission)
    Phronomy::MultiAgent::ReservedChildAdmission.new(persistence: stores.team, owner: reservation_owner).admit(admission)
    admission.result
  end

  def cancel_reserved_parent
    stores.team.transaction do |tx|
      current = tx.team_executions.load(reserved_run.team_execution_id)
      tx.team_executions.save(current.team_execution_id, expected_revision: current.execution_revision,
        execution: current.with(metadata: current.metadata.merge("cancel_requested" => true)))
      yield if block_given?
    end
  end

  def prepare_handoff_target
    source_root = build_agent_root(prefix: "handoff-source")
    stores.agent.agents.create(source_root)
    source = build_execution(source_root).with(execution_revision: 0, status: :active, phase: :calling_llm,
      metadata: {"coordination" => {"kind" => "handoff", "main_agent_id" => source_root.agent_id}})
    stores.agent.executions.create_active(source)
    handed_off = source.with(status: :handed_off, phase: :handed_off,
      metadata: source.metadata.merge("handoff_target_execution_id" => child_execution_id))
    stores.agent.executions.save(source.execution_id, expected_revision: 0, execution: handed_off)
    now = Time.now.utc.iso8601(6)
    routing = Phronomy::Agent::HandoffState.new(main_agent_id: source_root.agent_id,
      handoff_revision: 1, active_agent_id: child_root.agent_id, active_handoff_context_ref: nil,
      phase: "target_pending", pending_source_execution_id: source.execution_id,
      pending_target_execution_id: child_execution_id, created_at: now, updated_at: now, metadata: {})
    stores.agent.handoff_states.save(source_root.agent_id, expected_revision: nil, state: routing)
    owner = {"kind" => "handoff", "main_agent_id" => source_root.agent_id, "handoff_revision" => 1}
    runner = Phronomy::MultiAgent::HandoffRunner.allocate
    runner.instance_variable_set(:@main_agent, Struct.new(:agent_id).new(source_root.agent_id))
    runner.instance_variable_set(:@persistence, stores.agent)
    [runner, source, owner]
  end

  before do
    stores.agent.agents.create(child_root)
    stores.team.teams.create(coordination_team)
    stores.team.team_executions.create_active(reserved_run)
  end
end

RSpec.shared_examples "atomic reserved child admission" do
  include_context "reserved child stores"

  it "commits the exact child and Agent revision through one participation scope" do
    execution, root = admit_reserved_child
    expect(execution.execution_id).to eq(child_execution_id)
    expect(stores.agent.agents.load(child_root.agent_id).to_h).to eq(root.to_h)
    expect(stores.agent.executions.load(child_execution_id).to_h).to eq(execution.to_h)
  end

  it "rejects a reservation cancelled before child acceptance" do
    cancel_reserved_parent
    expect { admit_reserved_child }.to raise_error(Phronomy::CancellationError)
    expect(stores.agent.executions.list(child_root.agent_id)).to be_empty
  end

  it "rolls input and execution back if the Agent revision changed" do
    stores.agent.agents.save(child_root.agent_id, expected_revision: child_root.agent_revision,
      root: child_root.with(agent_revision: child_root.agent_revision + 1))
    expect { admit_reserved_child }.to raise_error(Phronomy::Persistence::ConflictError)
    expect(stores.agent.executions.list(child_root.agent_id)).to be_empty
  end

  it "does not turn a successful savepoint into an independently committed acceptance" do
    admission = new_child_admission
    expect do
      stores.coordinator.atomic do
        admit_reserved_child(admission)
      end
    end.to raise_error(Phronomy::Persistence::TransactionError, /not committed/)
    expect(stores.agent.executions.list(child_root.agent_id)).to be_empty
    expect { admission.result }.to raise_error(Phronomy::Persistence::TransactionError)
  end
  it "signals a Handoff target that has committed acceptance before cancellation" do
    runner, source, owner = prepare_handoff_target
    admission = Phronomy::Agent::Admission.new(persistence: stores.agent, root: child_root,
      input: "target", config: {phronomy_reserved_execution_id: child_execution_id,
                                phronomy_coordination: owner}, preparation_metadata: {})
    Phronomy::MultiAgent::ReservedChildAdmission.new(persistence: stores.agent, owner: owner).admit(admission)
    expect(Phronomy::Agent::ExecutionCancellation).to receive(:signal).with(child_execution_id, child_root.agent_id).once
    expect(runner.cancel(source.execution_id)).to include(execution_id: child_execution_id, cancellation_requested: true)
  end

end
