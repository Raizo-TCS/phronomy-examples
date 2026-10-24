# frozen_string_literal: true

require "rails_helper"

# Real Agent execution and output validation; only the HTTP response is fixed.
RSpec.describe "CveScanner.call_agent_json" do
  let(:notifications) { double("notification sink") }
  let(:broadcasts) { [] }

  before do
    allow(notifications).to receive(:publish) { |payload| broadcasts << payload }
  end

  after { Phronomy.reset_runtime! }

  def call_agent_result(agent_class = CveScanner::CveAnalystAgent, prompt = "prompt", **options)
    Phronomy::Agent.open_scope do |agents|
      CveScanner.call_agent_json(agent_class, prompt, agents: agents, notifications: notifications, **options)
    end
  end

  it "returns an immutable validated object and publishes completion after tokens" do
    value = {"decision" => "done", "vulnerability_status" => {"CVE-2023-52160" => "vulnerable"}, "reasoning" => {"CVE-2023-52160" => "affected version"}}
    stub = NotificationChatStub.new { value.to_json }
    result = call_agent_result
    expect(result).to eq(value)
    expect(result).to be_frozen
    expect(broadcasts.first[:type]).to eq("chat_turn_start")
    expect(broadcasts.map { |item| item[:type] }).to include("llm_token")
    expect(broadcasts.last[:type]).to eq("chat_turn_done")
    expect(JSON.parse(broadcasts.last[:content])).to eq(value)
    expect(stub.calls.length).to eq(1)
    expect(stub.calls.first).not_to have_key("response_format")
    expect(stub.calls.first.fetch("tools")).not_to be_empty
  end

  [["```json\n{\"decision\":\"done\"}\n```", "invalid_json"],
    ['Prose {"decision":"done"} after', "invalid_json"],
    ['{"decision":"done"', "invalid_json"],
    ["unparseable", "invalid_json"],
    ['{"decision":"done","decision":"need_more"}', "invalid_json"],
    ['{"decision":4}', "schema_mismatch"],
    ['{"decision":"need_more","proposed_commands":"uname -r"}', "schema_mismatch"]].each do |body, reason|
    it "reports #{reason} without repair, fallback business values or completion notifications" do
      stub = NotificationChatStub.new { body }
      expect { call_agent_result }.to raise_error(Phronomy::Agent::OutputError) { |error| expect(error.reason).to eq(reason) }
      expect(broadcasts.map { |item| item[:type] }).not_to include("chat_turn_done")
      expect(stub.calls.length).to eq(1)
    end
  end

  it "keeps custom roles and does not require a notification sink" do
    NotificationChatStub.new { '{"decision":"need_more","proposed_commands":["uname -r"]}' }
    result = call_agent_result(role: "CveAnalyst")
    expect(result["proposed_commands"]).to eq(["uname -r"])
    expect(broadcasts.values_at(0, -1).map { |event| event[:role] }).to eq(%w[CveAnalyst CveAnalyst])
    broadcasts.clear
    expect(call_agent_result(notifications: nil)["decision"]).to eq("need_more")
    expect(broadcasts).to be_empty
  end

  it "validates remediation and follow-up shapes through the same operation" do
    NotificationChatStub.new { |_body, index| index.zero? ? '{"decision":"complete"}' : '{"decision":"answered","answer":"Details"}' }
    expect(call_agent_result(CveScanner::RemediationAdvisorAgent)["decision"]).to eq("complete")
    expect(call_agent_result(CveScanner::FollowupAgent)["answer"]).to eq("Details")
  end

  it "retains Tool notification order and does not replay the Tool after invalid output" do
    count = 0
    tool = Class.new(Phronomy::Tool::Base) do
      tool_name "read_fixture"
      description "A controlled read"
      define_method(:execute) { count += 1; "fixture" }
    end
    klass = Class.new(CveScanner::CveAnalystAgent) do
      agent_definition id: "cve-json-tool-test", version: 1
      tools tool => nil
    end
    stub_const("CveJsonToolAgent", klass)
    stub = NotificationChatStub.new do |_body, index|
      index.zero? ? {role: "assistant", content: nil, tool_calls: [{id: "test-read", type: "function", function: {name: "read_fixture", arguments: "{}"}}]} : "invalid"
    end
    expect { call_agent_result(klass) }.to raise_error(Phronomy::Agent::OutputError)
    types = broadcasts.map { |event| event[:subtype] || event[:type] }
    expect(types.index("tool_call")).to be < types.index("tool_result")
    expect(broadcasts.find { |event| event[:subtype] == "tool_result" }.fetch(:message))
      .to include("read_fixture result (7 chars)")
    expect(types).not_to include("chat_turn_done")
    expect(count).to eq(1)
    expect(stub.calls.length).to eq(2)
    expect(stub.calls).to all(satisfy { |body| !body.key?("response_format") })
  end

  [[%w[first_read second_read], true], [%w[first_read first_read], true],
    [%w[first_read second_read], false]].each do |names, notify|
    it "attributes #{names.join(', ')} results to their own events with notifications=#{notify}" do
      counts = Hash.new(0)
      tool_classes = %w[first_read second_read].map do |name|
        Class.new(Phronomy::Tool::Base) do
          tool_name name
          description "Read a controlled fixture"
          define_method(:execute) { counts[name] += 1; "#{name}-result" }
        end
      end
      klass = Class.new(CveScanner::CveAnalystAgent) do
        agent_definition id: "cve-batch-tool-log", version: 1
        tools tool_classes[0] => nil, tool_classes[1] => nil
      end
      stub_const("CveBatchToolLogAgent", klass)
      stub = NotificationChatStub.new do |_body, index|
        if index.zero?
          {role: "assistant", content: nil, tool_calls: names.each_with_index.map { |name, call_index|
            {id: "batch-#{call_index}", type: "function", function: {name: name, arguments: "{}"}}
          }}
        else
          '{"decision":"done"}'
        end
      end
      result = call_agent_result(klass, "read the fixtures",
        role: "Analyst", notifications: notify ? notifications : nil)
      expect(result.fetch("decision")).to eq("done")
      expect(counts).to eq(names.tally)
      expect(stub.calls.length).to eq(2)
      expect(stub.calls).to all(satisfy { |body| body["stream"] && !body.key?("response_format") })
      if notify
        logs = broadcasts.select { |event| %w[tool_call tool_result].include?(event[:subtype]) }
        expect(logs.map { |event| event[:subtype] }).to eq(%w[tool_call tool_call tool_result tool_result])
        expect(logs.last(2).map { |event| event[:message] }).to eq(names.map { |name|
          "Analyst <- #{name} result (#{"#{name}-result".length} chars)"
        })
        expect(broadcasts.last).to include(type: "chat_turn_done", role: "Analyst")
      else
        expect(broadcasts).to be_empty
      end
    end
  end

  it "retains the explicit deterministic mock mode" do
    ClimateControl.modify(CVE_SCANNER_MOCK_LLM: "1") do
      expect(CveScanner::CveAnalystAgent).not_to receive(:create)
      value = call_agent_result(CveScanner::CveAnalystAgent, "CVE-2023-52160 and CVE-2024-00001")
      expect(value["vulnerability_status"].keys).to contain_exactly("CVE-2023-52160", "CVE-2024-00001")
      expect(call_agent_result(CveScanner::FollowupAgent)["decision"]).to eq("answered")
      expect(call_agent_result(CveScanner::RemediationAdvisorAgent)["decision"]).to eq("complete")
      expect(broadcasts.map { |event| event[:type] }).to include("chat_turn_start", "chat_turn_done")
    end
  end
end
