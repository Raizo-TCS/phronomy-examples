# frozen_string_literal: true

require "spec_helper"
require_relative "../../shared/reserved_child_admission_contract"

RSpec.describe "PostgreSQL reservation and admission ordering" do
  let(:stores) { build_postgresql_persistence.first }
  include_context "reserved child stores"

  it "waits for an earlier cancellation commit and then rejects the child" do
    ready, release, started = Queue.new, Queue.new, Queue.new
    cancel_thread = Thread.new {
      cancel_reserved_parent {
        ready << true
        release.pop
      }
    }
    Timeout.timeout(5) { ready.pop }
    admit_thread = Thread.new do
      stores.coordinator.backend.connection_pool.with_connection do |connection|
        started << postgresql_backend_pid(connection)
        admit_reserved_child
      rescue => error
        error
      end
    end
    pid = Timeout.timeout(5) { started.pop }
    wait_until_postgresql_blocked(stores, pid)
    release << true
    thread_value(cancel_thread)
    expect(thread_value(admit_thread)).to be_a(Phronomy::CancellationError)
    expect(stores.agent.executions.list(child_root.agent_id)).to be_empty
  ensure
    release << true if release
    [cancel_thread, admit_thread].compact.each { |thread| thread.kill if thread.alive? }
  end

  it "keeps the parent lock until child acceptance commits before cancellation" do
    ready, release, started = Queue.new, Queue.new, Queue.new
    admit_thread = Thread.new do
      admission = new_child_admission
      admission.define_singleton_method(:accept_in) do |scope|
        ready << true
        release.pop
        super(scope)
      end
      admit_reserved_child(admission)
    end
    Timeout.timeout(5) { ready.pop }
    cancel_thread = Thread.new do
      stores.coordinator.backend.connection_pool.with_connection do |connection|
        started << postgresql_backend_pid(connection)
        cancel_reserved_parent
      end
    end
    pid = Timeout.timeout(5) { started.pop }
    wait_until_postgresql_blocked(stores, pid)
    release << true
    execution, = thread_value(admit_thread)
    thread_value(cancel_thread)
    expect(stores.agent.executions.load(execution.execution_id).active?).to be(true)
    expect(stores.multi_agent.team_executions.load(reserved_run.team_execution_id).metadata.fetch("cancel_requested")).to be(true)
  ensure
    release << true if release
    [cancel_thread, admit_thread].compact.each { |thread| thread.kill if thread.alive? }
  end
  it "rechecks an absent Handoff target after waiting for its admission lock" do
    runner, source, owner = prepare_handoff_target
    expect(stores.agent).to receive(:request_cancellation).with(agent_id: child_root.agent_id, execution_id: child_execution_id, scope: anything).and_call_original
    ready, release, started = Queue.new, Queue.new, Queue.new
    admit_thread = Thread.new do
      admission = Phronomy::Agent::Admission.new(persistence: stores.agent, root: child_root,
        input: "target", config: {phronomy_reserved_execution_id: child_execution_id,
                                  phronomy_reservation: owner}, preparation_metadata: {})
      admission.define_singleton_method(:accept_in) do |scope|
        ready << true
        release.pop
        super(scope)
      end
      Phronomy::MultiAgent::ReservedChildAdmission.new(persistence: stores.multi_agent, owner: owner).admit(admission)
    end
    Timeout.timeout(5) { ready.pop }
    cancel_thread = Thread.new do
      stores.coordinator.backend.connection_pool.with_connection do |connection|
        started << postgresql_backend_pid(connection)
        runner.cancel(source.execution_id)
      end
    end
    wait_until_postgresql_blocked(stores, Timeout.timeout(5) { started.pop })
    release << true
    thread_value(admit_thread)
    expect(thread_value(cancel_thread)).to include(execution_id: child_execution_id, cancellation_requested: true)
    expect(stores.multi_agent.handoff_states.load(owner.fetch("main_agent_id")).metadata.fetch("cancelled_execution_ids")).to include(child_execution_id)
  ensure
    release << true if release
    [cancel_thread, admit_thread].compact.each { |thread| thread.kill if thread.alive? }
  end
end
