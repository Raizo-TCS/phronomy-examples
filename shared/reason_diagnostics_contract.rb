# frozen_string_literal: true

require_relative "../spec/spec_helper"
require_relative "../21_team_coordinator/agents"

# Exercise confirmed operation failure through the public Agent/Team APIs.
# Runtime teardown and a new pool verify reconnect readability, not a process
# crash or an external-effect guarantee. Only the provider HTTP boundary is stubbed.
RSpec.shared_examples "persisted reason diagnostics" do
  def reopen_reason_storage
    Phronomy.reset_runtime!
    initial_storage.fetch(1).disconnect!
    stores, pool = reopened_storage
    expect(pool).not_to equal(initial_storage.fetch(1))
    stores
  end

  it "retains confirmed Agent and Team reasons across resume and a new connection pool" do
    stores = initial_storage.fetch(0)
    stub = ExampleChatStub.new do |_request, index|
      case index
      when 0 then ExampleChatStub.tool("enqueue_task", description: "First")
      when 1 then ExampleChatStub.tool("finalize")
      when 2 then ExampleChatStub.tool("enqueue_task", description: "Too late")
      else raise "Confirmed failure must not repeat provider work"
      end
    end
    team = BlogWritingTeam.create(team_id: "reason-rejection", persistence: stores.multi_agent)
    expect { team.invoke("plan") }.to raise_error(Phronomy::Error) { |error|
      expect(error).not_to be_a(Phronomy::ExecutionRehydrationRequiredError)
      expect(error.code).to eq("team.enqueue_after_finalize")
    }

    run = team.executions.first
    expect(run.status).to eq("failed")
    coordinator_id = run.coordinator.fetch("execution_id")
    coordinator = stores.agent.executions.load(coordinator_id)
    expect(coordinator.status).to eq(:failed)
    expected_diagnostic = {
      "class" => "Phronomy::ConfigurationError",
      "message" => "Cannot enqueue after finalize",
      "code" => "team.enqueue_after_finalize"
    }
    expect(stores.agent.contents.fetch_json(coordinator.error_ref)).to eq(expected_diagnostic)
    expect(team.result(run.team_execution_id).dig(:error, "code")).to eq("team.enqueue_after_finalize")
    expect { team.resume(run.team_execution_id) }.to raise_error(Phronomy::Error) { |error|
      expect(error.code).to eq("team.enqueue_after_finalize")
    }
    expect(stub.calls.length).to eq(3)

    restored = reopen_reason_storage
    loaded = BlogWritingTeam.load(team.team_id, persistence: restored.multi_agent)
    restored_coordinator = restored.agent.executions.load(coordinator_id)
    expect(restored.agent.contents.fetch_json(restored_coordinator.error_ref)).to eq(expected_diagnostic)
    expect(loaded.executions.first.to_h).to eq(run.to_h)
    outcome = loaded.result(run.team_execution_id)
    expect(outcome.fetch(:status)).to eq("failed")
    expect(outcome.fetch(:error)).to eq(expected_diagnostic)
    expect { loaded.resume(run.team_execution_id) }.to raise_error(Phronomy::Error) { |error|
      expect(error).not_to be_a(Phronomy::ExecutionRehydrationRequiredError)
      expect(error.code).to eq("team.enqueue_after_finalize")
    }
    expect(stub.calls.length).to eq(3)
  end

  it "reads an old diagnostic without inferring a code from its message" do
    diagnostic = {"class" => "Phronomy::ConfigurationError", "message" => "Cannot enqueue after finalize"}
    reference = initial_storage.fetch(0).agent.contents.put_json(diagnostic)

    restored = reopen_reason_storage
    expect(restored.agent.contents.fetch_json(reference)).to eq(diagnostic)
  end

  it "preserves an unknown reason code without normalization" do
    diagnostic = {
      "class" => "Phronomy::ConfigurationError",
      "message" => "Future failure",
      "code" => "future.unknown"
    }
    reference = initial_storage.fetch(0).agent.contents.put_json(diagnostic)

    restored = reopen_reason_storage
    expect(restored.agent.contents.fetch_json(reference)).to eq(diagnostic)
  end
end
