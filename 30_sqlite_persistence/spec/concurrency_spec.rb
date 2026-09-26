# frozen_string_literal: true

require "spec_helper"

RSpec.describe "ActiveRecord SQLite Persistence concurrency" do
  let(:persistence) { build_sqlite_persistence(pool_size: 10, timeout: 10_000).first }

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

  it "serializes transactional idle-check plus admission against another writer" do
    root = build_agent_root
    persistence.agents.create(root)
    first = build_execution(root)
    second = build_execution(root)

    idle_checked = Queue.new
    allow_first_admission = Queue.new
    second_started = Queue.new

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
      second_started << true
      persistence.executions.create_active(second)
      :second_ok
    rescue StandardError => e
      e
    end

    second_started.pop
    allow_first_admission << true

    expect(first_thread.value).to eq(:first_ok)
    expect(second_thread.value).to be_a(Phronomy::AgentBusyError)
    expect(persistence.executions.list_active(root.agent_id).map(&:execution_id))
      .to eq([first.execution_id])
  ensure
    first_thread&.kill if first_thread&.alive?
    second_thread&.kill if second_thread&.alive?
  end
end
