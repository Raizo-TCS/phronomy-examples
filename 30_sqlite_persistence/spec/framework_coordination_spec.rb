# frozen_string_literal: true

require "spec_helper"
require_relative "../../spec/spec_helper"
require_relative "../../17_multi_agent_handoff/agents"
require_relative "../../21_team_coordinator/agents"

RSpec.describe "Sample coordination through the real SQLite adapter" do
  it "restores the active Handoff specialist from SQLite in a fresh Runtime" do
    stores, pool = build_sqlite_persistence
    runner = HandoffDemo.build_runner(persistence: stores)
    stub = ExampleChatStub.new do |request, index|
      if index.zero?
        edge = request.fetch("tools").map { |tool| tool.fetch("function") }
          .find { |tool| tool.fetch("description").include?("billing, invoice") }
        ExampleChatStub.tool(edge.fetch("name"), responsibility: "Resolve the invoice discrepancy")
      else
        "The billing specialist has checked the invoice and resolved the discrepancy."
      end
    end
    first = runner.invoke("My invoice is wrong")
    expect(first.fetch(:agent)).to be_a(BillingAgent)
    edges = runner.handoffs
    participants = ([runner.main_agent] + edges.map(&:target_agent)).to_h { |agent| [agent.agent_id, agent.class] }
    main_id = runner.main_agent.agent_id
    Phronomy.reset_runtime!
    pool.disconnect!

    restored = Phronomy::PersistenceComposition.build(backend: PhronomyExamples::Persistence::ActiveRecordSQLite.new(connection_pool: pool))
    owners = participants.to_h { |id, klass| [id, klass.load(id, persistence: restored.agent)] }
    loaded_edges = edges.map do |edge|
      Phronomy::MultiAgent::Handoff.new(source_agent: owners.fetch(edge.source_agent.agent_id),
        target_agent: owners.fetch(edge.target_agent.agent_id), description: edge.description)
    end
    loaded = Phronomy::MultiAgent::HandoffRunner.new(main_agent: owners.fetch(main_id), handoffs: loaded_edges, persistence: restored.multi_agent)
    expect(loaded.invoke("Here is another invoice detail").fetch(:agent).agent_id).to eq(first.fetch(:agent).agent_id)
    expect(stub.calls.length).to eq(3)
  end

  it "reads a terminal Team aggregate after SQLite reconnection without re-executing children" do
    stores, pool = build_sqlite_persistence
    stub = ExampleChatStub.new do |_request, index|
      case index
      when 0 then ExampleChatStub.tool("enqueue_task", description: "Write the introduction")
      when 1 then ExampleChatStub.tool("finalize")
      else "An introduction that describes Ruby concurrency, stores and useful application examples."
      end
    end
    team = BlogWritingTeam.create(team_id: "sqlite-blog-team", persistence: stores.multi_agent)
    result = team.invoke("Ruby concurrency")
    run = stores.multi_agent.runs(team.team_id).fetch(0)
    calls_before = stub.calls.length
    Phronomy.reset_runtime!
    pool.disconnect!

    restored = Phronomy::PersistenceComposition.build(backend: PhronomyExamples::Persistence::ActiveRecordSQLite.new(connection_pool: pool))
    loaded = BlogWritingTeam.load(team.team_id, persistence: restored.multi_agent)
    expect(loaded.resume(run.team_execution_id)).to eq(result)
    expect(restored.multi_agent.team_executions.load(run.team_execution_id).assignments).to eq(run.assignments)
    expect(stub.calls.length).to eq(calls_before)
  end
end

RSpec.describe "Reason diagnostics through SQLite" do
  it "preserves confirmed Team and Agent codes after a fresh-pool reload" do
    stores, pool = build_sqlite_persistence
    stub = ExampleChatStub.new do |_request, index|
      case index
      when 0 then ExampleChatStub.tool("enqueue_task", description: "First")
      when 1 then ExampleChatStub.tool("finalize")
      else ExampleChatStub.tool("enqueue_task", description: "Too late")
      end
    end
    team = BlogWritingTeam.create(team_id: "sqlite-rejection", persistence: stores.multi_agent)
    expect { team.invoke("plan") }.to raise_error(Phronomy::Error) { |error|
      expect(error.code).to eq("team.enqueue_after_finalize")
    }
    run = team.executions.first
    coordinator = stores.agent.executions.load(run.coordinator.fetch("execution_id"))
    expect(stores.agent.contents.fetch_json(coordinator.error_ref).fetch("code")).to eq("team.enqueue_after_finalize")
    Phronomy.reset_runtime!
    pool.disconnect!
    restored = PhronomyActiveRecord.build(connection_pool: pool, dialect: :sqlite)
    loaded = BlogWritingTeam.load(team.team_id, persistence: restored.multi_agent)
    expect(loaded.result(run.team_execution_id).dig(:error, "code")).to eq("team.enqueue_after_finalize")
    expect { loaded.resume(run.team_execution_id) }.to raise_error(Phronomy::Error) { |error|
      expect(error.code).to eq("team.enqueue_after_finalize")
    }
    expect(stub.calls.length).to eq(3)
  end

  it "round-trips old and unknown reason diagnostics without normalization" do
    stores, pool = build_sqlite_persistence
    old = {"class" => "Phronomy::ConfigurationError", "message" => "Cannot enqueue after finalize"}
    unknown = old.merge("code" => "future.unknown")
    refs = [old, unknown].map { |record| stores.agent.contents.put_json(record) }
    pool.disconnect!
    reader = PhronomyActiveRecord.build(connection_pool: pool, dialect: :sqlite)
    expect(refs.map { |ref| reader.agent.contents.fetch_json(ref) }).to eq([old, unknown])
  end
end
