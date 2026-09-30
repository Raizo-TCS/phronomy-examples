# frozen_string_literal: true

require "spec_helper"
require_relative "../../shared/reserved_child_admission_contract"

RSpec.describe "PostgreSQL reservation and admission ordering" do
  let(:persistence) { build_postgresql_persistence.first }
  include_context "reserved child persistence"

  it "waits for an earlier cancellation commit and then rejects the child" do
    ready, release, started = Queue.new, Queue.new, Queue.new
    cancel_thread = Thread.new { cancel_reserved_parent { ready << true; release.pop } }
    Timeout.timeout(5) { ready.pop }
    admit_thread = Thread.new do
      persistence.backend.connection_pool.with_connection do |connection|
        started << postgresql_backend_pid(connection)
        admit_reserved_child
      rescue => error
        error
      end
    end
    pid = Timeout.timeout(5) { started.pop }
    wait_until_postgresql_blocked(persistence, pid)
    release << true
    thread_value(cancel_thread)
    expect(thread_value(admit_thread)).to be_a(Phronomy::CancellationError)
    expect(persistence.executions.list(child_root.agent_id)).to be_empty
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
      persistence.backend.connection_pool.with_connection do |connection|
        started << postgresql_backend_pid(connection)
        cancel_reserved_parent
      end
    end
    pid = Timeout.timeout(5) { started.pop }
    wait_until_postgresql_blocked(persistence, pid)
    release << true
    execution, = thread_value(admit_thread)
    thread_value(cancel_thread)
    expect(persistence.executions.load(execution.execution_id).active?).to be(true)
    expect(persistence.team_executions.load(reserved_run.team_execution_id).metadata.fetch("cancel_requested")).to be(true)
  ensure
    release << true if release
    [cancel_thread, admit_thread].compact.each { |thread| thread.kill if thread.alive? }
  end
  it "rechecks an absent Handoff target after waiting for its admission lock" do
    runner, source, owner = prepare_handoff_target
    expect(Phronomy::Agent::ExecutionCancellation).to receive(:signal).with(child_execution_id, child_root.agent_id).once
    ready, release, started = Queue.new, Queue.new, Queue.new
    admit_thread = Thread.new do
      admission = Phronomy::Agent::Admission.new(persistence: persistence, root: child_root,
        input: "target", config: {phronomy_reserved_execution_id: child_execution_id,
                                  phronomy_coordination: owner}, preparation_metadata: {})
      admission.define_singleton_method(:accept_in) do |scope|
        ready << true
        release.pop
        super(scope)
      end
      Phronomy::MultiAgent::ReservedChildAdmission.new(persistence: persistence, owner: owner).admit(admission)
    end
    Timeout.timeout(5) { ready.pop }
    cancel_thread = Thread.new do
      persistence.backend.connection_pool.with_connection do |connection|
        started << postgresql_backend_pid(connection)
        runner.cancel(source.execution_id)
      end
    end
    wait_until_postgresql_blocked(persistence, Timeout.timeout(5) { started.pop })
    release << true
    thread_value(admit_thread)
    expect(thread_value(cancel_thread)).to include(execution_id: child_execution_id, cancellation_requested: true)
    expect(persistence.handoff_states.load(owner.fetch("main_agent_id")).metadata.fetch("cancelled_execution_ids")).to include(child_execution_id)
  ensure
    release << true if release
    [cancel_thread, admit_thread].compact.each { |thread| thread.kill if thread.alive? }
  end

end
