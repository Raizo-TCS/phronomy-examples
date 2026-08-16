# frozen_string_literal: true

require "spec_helper"

RSpec.describe "ActiveRecord PostgreSQL Persistence concurrency" do
  let(:persistence) { build_postgresql_persistence.first }

  it "admits exactly one active execution for the same Agent" do
    root = build_agent_root
    persistence.agents.create(root)
    first = build_execution(root)
    second = build_execution(root)

    results = run_concurrently(
      -> { persistence.executions.create_active(first) },
      -> { persistence.executions.create_active(second) }
    )

    expect(results.count { |kind, _| kind == :ok }).to eq(1)
    errors = results.filter_map { |kind, value| value if kind == :error }
    expect(errors.length).to eq(1)
    expect(errors.first).to be_a(Phronomy::AgentBusyError)
    expect(persistence.executions.list_active(root.agent_id).length).to eq(1)
  end

  it "allows exactly one Agent CAS writer from the same revision" do
    root = build_agent_root
    persistence.agents.create(root)
    updated = root.with(agent_revision: 1, lifecycle_status: :active)

    results = run_concurrently(
      -> { persistence.agents.save(root.agent_id, expected_revision: 0, root: updated) },
      -> { persistence.agents.save(root.agent_id, expected_revision: 0, root: updated) }
    )

    expect(results.count { |kind, _| kind == :ok }).to eq(1)
    errors = results.filter_map { |kind, value| value if kind == :error }
    expect(errors.length).to eq(1)
    expect(errors.first).to be_a(Phronomy::Persistence::ConflictError)
    expect(persistence.agents.load(root.agent_id).agent_revision).to eq(1)
  end

  it "allows exactly one Execution CAS writer from the same revision" do
    root = build_agent_root
    persistence.agents.create(root)
    execution = build_execution(root)
    persistence.executions.create_active(execution)
    updated = execution.with(status: :active, phase: :calling_llm)

    results = run_concurrently(
      lambda {
        persistence.executions.save(
          execution.execution_id,
          expected_revision: 0,
          execution: updated
        )
      },
      lambda {
        persistence.executions.save(
          execution.execution_id,
          expected_revision: 0,
          execution: updated
        )
      }
    )

    expect(results.count { |kind, _| kind == :ok }).to eq(1)
    errors = results.filter_map { |kind, value| value if kind == :error }
    expect(errors.length).to eq(1)
    expect(errors.first).to be_a(Phronomy::Persistence::ConflictError)
    expect(
      persistence.executions.load(execution.execution_id).execution_revision
    ).to eq(1)
  end

  it "allows exactly one Journal append from the same expected position" do
    root = build_agent_root
    persistence.agents.create(root)

    results = run_concurrently(
      lambda {
        persistence.journals.append(
          root.agent_id,
          expected_position: 0,
          records: [build_journal_record(root.agent_id)]
        )
      },
      lambda {
        persistence.journals.append(
          root.agent_id,
          expected_position: 0,
          records: [build_journal_record(root.agent_id)]
        )
      }
    )

    expect(results.count { |kind, _| kind == :ok }).to eq(1)
    errors = results.filter_map { |kind, value| value if kind == :error }
    expect(errors.length).to eq(1)
    expect(errors.first).to be_a(Phronomy::Persistence::ConflictError)
    expect(persistence.journals.head(root.agent_id)).to eq(1)
    expect(persistence.journals.read(root.agent_id).length).to eq(1)
  end

  it "allows exactly one Workflow initial save for the same thread_id" do
    thread_id = "workflow-#{SecureRandom.uuid}"

    results = run_concurrently(
      lambda {
        persistence.workflow_states.save(
          thread_id,
          expected_revision: nil,
          snapshot: {fields: {writer: 1}, phase: "pause"}
        )
      },
      lambda {
        persistence.workflow_states.save(
          thread_id,
          expected_revision: nil,
          snapshot: {fields: {writer: 2}, phase: "pause"}
        )
      }
    )

    expect(results.count { |kind, _| kind == :ok }).to eq(1)
    errors = results.filter_map { |kind, value| value if kind == :error }
    expect(errors.length).to eq(1)
    expect(errors.first).to be_a(Phronomy::Persistence::ConflictError)
    expect(persistence.workflow_states.load(thread_id)[:revision]).to eq(1)
  end

  it "allows a different Agent writer to finish while another Agent row is locked" do
    first_root = build_agent_root(prefix: "parallel-a")
    second_root = build_agent_root(prefix: "parallel-b")
    persistence.agents.create(first_root)
    persistence.agents.create(second_root)

    first_locked = Queue.new
    release_first = Queue.new

    first_thread = Thread.new do
      persistence.transaction do |tx|
        tx.executions.assert_idle!(first_root.agent_id)
        first_locked << true
        release_first.pop
      end
      :first_ok
    rescue StandardError => e
      e
    end

    first_locked.pop

    second_thread = Thread.new do
      persistence.executions.create_active(build_execution(second_root))
      :second_ok
    rescue StandardError => e
      e
    end

    expect(Timeout.timeout(5) { second_thread.value }).to eq(:second_ok)

    release_first << true
    expect(thread_value(first_thread)).to eq(:first_ok)
  ensure
    release_first << true if release_first && first_thread&.alive?
    first_thread&.kill if first_thread&.alive?
    second_thread&.kill if second_thread&.alive?
  end

  it "shows a same-Agent CAS writer blocked on the PostgreSQL row lock before becoming stale" do
    root = build_agent_root(prefix: "row-lock")
    persistence.agents.create(root)

    first_update = root.with(agent_revision: 1, lifecycle_status: :active)
    second_update = root.with(agent_revision: 1, lifecycle_status: :closed)

    first_written = Queue.new
    release_first = Queue.new
    second_pid = Queue.new

    first_thread = Thread.new do
      persistence.transaction do |tx|
        tx.agents.save(root.agent_id, expected_revision: 0, root: first_update)
        first_written << true
        release_first.pop
      end
      :first_ok
    rescue StandardError => e
      e
    end

    first_written.pop

    second_thread = Thread.new do
      with_bound_postgresql_transaction(persistence) do |tx, connection|
        second_pid << postgresql_backend_pid(connection)
        tx.agents.save(root.agent_id, expected_revision: 0, root: second_update)
      end
      :second_ok
    rescue StandardError => e
      e
    end

    pid = second_pid.pop
    expect(wait_until_postgresql_blocked(persistence, pid)).to be(true)

    release_first << true

    expect(thread_value(first_thread)).to eq(:first_ok)
    expect(thread_value(second_thread)).to be_a(Phronomy::Persistence::ConflictError)
    expect(persistence.agents.load(root.agent_id).lifecycle_status).to eq(:active)
  ensure
    release_first << true if release_first && first_thread&.alive?
    first_thread&.kill if first_thread&.alive?
    second_thread&.kill if second_thread&.alive?
  end

  it "keeps transactional idle-check and admission on the same per-Agent lock boundary" do
    root = build_agent_root(prefix: "admission-lock")
    persistence.agents.create(root)
    first = build_execution(root)
    second = build_execution(root)

    idle_checked = Queue.new
    allow_first_admission = Queue.new
    second_pid = Queue.new

    first_thread = Thread.new do
      persistence.transaction do |tx|
        tx.executions.assert_idle!(root.agent_id)
        idle_checked << true
        allow_first_admission.pop
        tx.executions.create_active(first)
      end
      :first_ok
    rescue StandardError => e
      e
    end

    idle_checked.pop

    second_thread = Thread.new do
      with_bound_postgresql_transaction(persistence) do |tx, connection|
        second_pid << postgresql_backend_pid(connection)
        tx.executions.create_active(second)
      end
      :second_ok
    rescue StandardError => e
      e
    end

    pid = second_pid.pop
    expect(wait_until_postgresql_blocked(persistence, pid)).to be(true)

    allow_first_admission << true

    expect(thread_value(first_thread)).to eq(:first_ok)
    expect(thread_value(second_thread)).to be_a(Phronomy::AgentBusyError)
    expect(persistence.executions.list_active(root.agent_id).map(&:execution_id))
      .to eq([first.execution_id])
  ensure
    allow_first_admission << true if allow_first_admission && first_thread&.alive?
    first_thread&.kill if first_thread&.alive?
    second_thread&.kill if second_thread&.alive?
  end

  it "uses one Agent-row lock order across Journal mutation and Execution admission" do
    root = build_agent_root(prefix: "cross-repo-lock")
    persistence.agents.create(root)
    execution = build_execution(root)

    journal_written = Queue.new
    release_journal = Queue.new
    execution_pid = Queue.new

    journal_thread = Thread.new do
      persistence.transaction do |tx|
        tx.journals.append(
          root.agent_id,
          expected_position: 0,
          records: [build_journal_record(root.agent_id)]
        )
        journal_written << true
        release_journal.pop
      end
      :journal_ok
    rescue StandardError => e
      e
    end

    journal_written.pop

    execution_thread = Thread.new do
      with_bound_postgresql_transaction(persistence) do |tx, connection|
        execution_pid << postgresql_backend_pid(connection)
        tx.executions.create_active(execution)
      end
      :execution_ok
    rescue StandardError => e
      e
    end

    pid = execution_pid.pop
    expect(wait_until_postgresql_blocked(persistence, pid)).to be(true)

    release_journal << true

    expect(thread_value(journal_thread)).to eq(:journal_ok)
    expect(thread_value(execution_thread)).to eq(:execution_ok)
    expect(persistence.journals.head(root.agent_id)).to eq(1)
    expect(persistence.executions.list_active(root.agent_id).map(&:execution_id))
      .to eq([execution.execution_id])
  ensure
    release_journal << true if release_journal && journal_thread&.alive?
    journal_thread&.kill if journal_thread&.alive?
    execution_thread&.kill if execution_thread&.alive?
  end

  it "surfaces an opposite multi-Agent lock-order deadlock as a database deadlock" do
    first_root = build_agent_root(prefix: "deadlock-a")
    second_root = build_agent_root(prefix: "deadlock-b")
    persistence.agents.create(first_root)
    persistence.agents.create(second_root)

    first_locked = Queue.new
    second_locked = Queue.new
    continue_first = Queue.new
    continue_second = Queue.new

    first_thread = Thread.new do
      persistence.transaction do |tx|
        tx.executions.assert_idle!(first_root.agent_id)
        first_locked << true
        continue_first.pop
        tx.executions.assert_idle!(second_root.agent_id)
      end
      :first_ok
    rescue StandardError => e
      e
    end

    second_thread = Thread.new do
      persistence.transaction do |tx|
        tx.executions.assert_idle!(second_root.agent_id)
        second_locked << true
        continue_second.pop
        tx.executions.assert_idle!(first_root.agent_id)
      end
      :second_ok
    rescue StandardError => e
      e
    end

    first_locked.pop
    second_locked.pop
    continue_first << true
    continue_second << true

    results = [
      thread_value(first_thread, timeout: 15),
      thread_value(second_thread, timeout: 15)
    ]

    expect(results.count { |result| result == :first_ok || result == :second_ok }).to eq(1)
    errors = results.grep(StandardError)
    expect(errors.length).to eq(1)
    expect(errors.first).to be_a(ActiveRecord::Deadlocked)
    expect(errors.first).not_to be_a(Phronomy::Persistence::ConflictError)
  ensure
    continue_first << true if continue_first && first_thread&.alive?
    continue_second << true if continue_second && second_thread&.alive?
    first_thread&.kill if first_thread&.alive?
    second_thread&.kill if second_thread&.alive?
  end
end
