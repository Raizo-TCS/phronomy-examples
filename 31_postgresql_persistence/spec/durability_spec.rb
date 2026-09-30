# frozen_string_literal: true

require "spec_helper"

RSpec.describe "ActiveRecord PostgreSQL Persistence durability" do
  it "reloads all 5 durable repositories through a fresh ActiveRecord pool" do
    first_backend, first_pool = build_postgresql_persistence

    root = build_agent_root(prefix: "durable-agent")
    first_backend.agent.agents.create(root)

    content_id = first_backend.agent.contents.put_text("durable PostgreSQL content")
    appended = first_backend.agent.journals.append(
      root.agent_id,
      expected_position: 0,
      records: [
        Phronomy::Agent::JournalRecord.new(
          agent_id: root.agent_id,
          kind: :knowledge,
          channel: :context,
          role: :user,
          content_ref: content_id,
          context_candidate: true
        )
      ]
    )

    updated = root.with(
      agent_revision: 1,
      journal_position: appended.length,
      lifecycle_status: :active
    )
    first_backend.agent.agents.save(
      root.agent_id,
      expected_revision: 0,
      root: updated
    )

    execution = build_execution(updated)
    first_backend.agent.executions.create_active(execution)

    thread_id = "durable-workflow-#{SecureRandom.uuid}"
    first_backend.workflow.save(
      thread_id,
      expected_revision: nil,
      snapshot: {fields: {value: "persisted"}, phase: "pause"}
    )

    first_pool.disconnect!

    second_backend, = build_postgresql_persistence

    expect(second_backend.agent.contents.fetch_text(content_id))
      .to eq("durable PostgreSQL content")
    expect(second_backend.agent.agents.load(root.agent_id).agent_revision).to eq(1)
    expect(second_backend.agent.journals.head(root.agent_id)).to eq(1)
    expect(second_backend.agent.journals.read(root.agent_id).first.content_ref).to eq(content_id)

    reloaded_execution = second_backend.agent.executions.load(execution.execution_id)
    expect(reloaded_execution.to_h).to eq(execution.to_h)

    workflow = second_backend.workflow.load(thread_id)
    expect(workflow[:revision]).to eq(1)
    expect(workflow[:snapshot]).to eq(
      "fields" => {"value" => "persisted"},
      "phase" => "pause"
    )
  end

  it "rejects unsupported Workflow values instead of using a Ruby object serializer" do
    stores = build_postgresql_persistence.first

    expect do
      stores.workflow.save(
        "unsupported-#{SecureRandom.uuid}",
        expected_revision: nil,
        snapshot: {fields: {object: Object.new}, phase: "pause"}
      )
    end.to raise_error(Phronomy::Persistence::SerializationError)
  end
end
