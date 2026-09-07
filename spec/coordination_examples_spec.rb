# frozen_string_literal: true

require "spec_helper"
require_relative "../17_multi_agent_handoff/agents"
require_relative "../21_team_coordinator/agents"

RSpec.describe "Current coordination examples" do
  it "executes all three Handoff CLI scenarios as independent conversations" do
    waiting_for_specialist = false
    stub = ExampleChatStub.new do |request, _index|
      tools = Array(request["tools"]).map { |tool| tool.fetch("function") }
      if waiting_for_specialist
        waiting_for_specialist = false
        "The specialist has investigated this issue and provided a clear resolution."
      else
        input = request.fetch("messages").reverse.find { |message| message["role"] == "user" }.fetch("content")
        pattern = input.include?("charged") ? /billing, invoice/ : /software errors/
        if input.include?("business hours")
          "Our customer support team is available during normal business hours."
        else
          edge = tools.find { |tool| tool.fetch("description").match?(pattern) }
          raise "Triage Handoff schema is missing" unless edge
          waiting_for_specialist = true
          ExampleChatStub.tool(edge.fetch("name"), responsibility: input)
        end
      end
    end

    expect { load File.expand_path("../17_multi_agent_handoff/run.rb", __dir__) }
      .to output(/Handled by: BillingAgent.*Handled by: TechSupportAgent.*Handled by: TriageAgent/m).to_stdout
    expect(stub.calls.length).to eq(5)
  end

  it "retains the specialist when the same conversation runner is reused" do
    runner = HandoffDemo.build_runner
    expect(runner.handoffs.flat_map { |edge| [edge.source_agent.persistence, edge.target_agent.persistence] }.uniq)
      .to eq([runner.main_agent.persistence])
    stub = ExampleChatStub.new do |request, index|
      if index.zero?
        edge = request.fetch("tools").map { |tool| tool.fetch("function") }
          .find { |tool| tool.fetch("description").include?("billing, invoice") }
        ExampleChatStub.tool(edge.fetch("name"), responsibility: "Resolve the billing issue")
      else
        "The billing specialist has answered this part of the conversation."
      end
    end
    first = runner.invoke("My invoice is wrong")
    second = runner.invoke("Here is another detail")
    expect(first.fetch(:agent)).to be_a(BillingAgent)
    expect(second.fetch(:agent)).to equal(first.fetch(:agent))
    expect(stub.calls.length).to eq(3)
  end

  it "executes the Team CLI and reads canonical string-keyed aggregate results" do
    stub = ExampleChatStub.new do |_request, index|
      if index < 4
        ExampleChatStub.tool("enqueue_task", description: "Write section #{index + 1}")
      elsif index == 4
        ExampleChatStub.tool("finalize")
      else
        "A detailed explanation of Ruby concurrency and practical coordination techniques for developers."
      end
    end
    expect { load File.expand_path("../21_team_coordinator/run.rb", __dir__) }
      .to output(/Final Blog Post: 4 sections/).to_stdout
    expect(stub.calls.length).to eq(10)
  end

  it "can read a completed Team result again after Runtime restart without Provider calls" do
    store = Phronomy::Persistence::InMemory.new
    stub = ExampleChatStub.new do |_request, index|
      case index
      when 0 then ExampleChatStub.tool("enqueue_task", description: "Write an introduction")
      when 1 then ExampleChatStub.tool("finalize")
      else "A durable section describing Ruby concurrency with a clear and useful example."
      end
    end
    team = BlogWritingTeam.create(team_id: "example-team-restart", persistence: store)
    expected = team.invoke("Ruby concurrency")
    id = store.list_team_executions(team.team_id).first.team_execution_id
    expect(expected.fetch("sections").first.fetch("content")).to include("durable section")
    calls_before = stub.calls.length
    Phronomy.reset_runtime!
    LLMConfig.apply_phronomy_defaults!
    loaded = BlogWritingTeam.load(team.team_id, persistence: store)
    expect(loaded.resume(id)).to eq(expected)
    expect(stub.calls.length).to eq(calls_before)
  end

  it "runs the standalone bounded-parallel CLI with the current Orchestrator API" do
    stub = ExampleChatStub.new { |_request, _index| "Positive sentiment, with useful product keywords." }
    expect { load File.expand_path("../23_bounded_parallel/run.rb", __dir__) }
      .to output(/Sentiment analysis.*Mixed analysis.*Done\./m).to_stdout
    expect(stub.calls.length).to eq(7)
  end

  it "runs the unified Agent and Workflow persistence CLI" do
    stub = ExampleChatStub.new { |_request, _index| "The persistence demo keyword is Aurora." }
    expect { load File.expand_path("../29_unified_persistence/run.rb", __dir__) }
      .to output(/Same-process load returns existing owner: true.*After approval:.*approved/m).to_stdout
    expect(stub.calls.length).to eq(1)
  end
end
