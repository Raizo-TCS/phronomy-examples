# frozen_string_literal: true

require "rails_helper"

# ---------------------------------------------------------------------------
# Unit tests for CveScanner.call_agent_json
#
# This method is the single point where LLM output enters the pipeline.
# It must reliably:
#   1. Parse clean JSON from the agent output.
#   2. Strip markdown code fences before parsing.
#   3. Extract the first {...} block when the LLM wraps JSON in prose.
#   4. Fall back gracefully when the output is completely unparseable.
#   5. Always broadcast chat_turn_done with clean, normalised JSON content.
# ---------------------------------------------------------------------------

RSpec.describe "CveScanner.call_agent_json" do
  # Minimal agent double: stream yields no events and returns a fixed output.
  def stub_agent_output(agent_class, output_str)
    agent_double = instance_double(agent_class)
    allow(agent_class).to receive(:new).and_return(agent_double)
    allow(agent_double).to receive(:stream).and_return([{output: output_str}])
    agent_double
  end

  let(:broadcasts) { [] }

  before do
    allow(ScanChannel).to receive(:broadcast) { |_id, payload| broadcasts << payload }
  end

  # ---------------------------------------------------------------------------
  # TC-01: clean JSON is parsed and rebroadcast verbatim.
  # ---------------------------------------------------------------------------
  describe "TC-01: clean JSON output" do
    let(:json_str) do
      '{"decision":"done","vulnerability_status":{"CVE-2023-52160":"vulnerable"},' \
        '"reasoning":{"CVE-2023-52160":"host is vulnerable"}}'
    end

    it "returns the parsed hash" do
      stub_agent_output(CveScanner::CveAnalystAgent, json_str)
      result = CveScanner.call_agent_json(CveScanner::CveAnalystAgent, "prompt", scan_id: 1)
      expect(result["decision"]).to eq("done")
      expect(result["vulnerability_status"]["CVE-2023-52160"]).to eq("vulnerable")
    end

    it "broadcasts chat_turn_done with clean JSON content" do
      stub_agent_output(CveScanner::CveAnalystAgent, json_str)
      CveScanner.call_agent_json(CveScanner::CveAnalystAgent, "prompt", scan_id: 1)
      done_event = broadcasts.find { |b| b[:type] == "chat_turn_done" }
      expect(done_event).not_to be_nil
      expect { JSON.parse(done_event[:content]) }.not_to raise_error
      expect(JSON.parse(done_event[:content])["decision"]).to eq("done")
    end
  end

  # ---------------------------------------------------------------------------
  # TC-02: JSON wrapped in ```json ... ``` code fence.
  # ---------------------------------------------------------------------------
  describe "TC-02: JSON in markdown code fence" do
    let(:fenced) do
      "```json\n{\"decision\":\"need_more\",\"proposed_commands\":[\"dpkg -s wpasupplicant\"]}\n```"
    end

    it "strips the fence and parses successfully" do
      stub_agent_output(CveScanner::CveAnalystAgent, fenced)
      result = CveScanner.call_agent_json(CveScanner::CveAnalystAgent, "prompt", scan_id: 1)
      expect(result["decision"]).to eq("need_more")
      expect(result["proposed_commands"]).to eq(["dpkg -s wpasupplicant"])
    end

    it "broadcasts clean JSON (no fence in content)" do
      stub_agent_output(CveScanner::CveAnalystAgent, fenced)
      CveScanner.call_agent_json(CveScanner::CveAnalystAgent, "prompt", scan_id: 1)
      done_event = broadcasts.find { |b| b[:type] == "chat_turn_done" }
      expect(done_event[:content]).not_to include("```")
    end
  end

  # ---------------------------------------------------------------------------
  # TC-03: JSON preceded and followed by prose (the bug observed in Scan 51).
  # ---------------------------------------------------------------------------
  describe "TC-03: JSON wrapped in prose" do
    let(:prose_wrapped) do
      'Based on my analysis of the available data:\n\n' \
        '{"decision":"done","vulnerability_status":{"CVE-2023-52160":"vulnerable"},' \
        '"reasoning":{"CVE-2023-52160":"affected version installed"}}\n\n' \
        'This concludes my assessment.'
    end

    it "extracts the JSON block and parses it" do
      stub_agent_output(CveScanner::CveAnalystAgent, prose_wrapped)
      result = CveScanner.call_agent_json(CveScanner::CveAnalystAgent, "prompt", scan_id: 1)
      expect(result["decision"]).to eq("done")
    end

    it "broadcasts clean JSON without surrounding prose" do
      stub_agent_output(CveScanner::CveAnalystAgent, prose_wrapped)
      CveScanner.call_agent_json(CveScanner::CveAnalystAgent, "prompt", scan_id: 1)
      done_event = broadcasts.find { |b| b[:type] == "chat_turn_done" }
      parsed = JSON.parse(done_event[:content])
      expect(parsed["decision"]).to eq("done")
    end
  end

  # ---------------------------------------------------------------------------
  # TC-04: completely unparseable output — falls back to need_more error marker.
  # ---------------------------------------------------------------------------
  describe "TC-04: completely unparseable output" do
    let(:garbage) { "I cannot determine the vulnerability status from the available data." }

    it "returns the json_parse_failed fallback hash" do
      stub_agent_output(CveScanner::CveAnalystAgent, garbage)
      result = CveScanner.call_agent_json(CveScanner::CveAnalystAgent, "prompt", scan_id: 1)
      expect(result["decision"]).to eq("need_more")
      expect(result["error"]).to eq("json_parse_failed")
    end

    it "does not raise an exception" do
      stub_agent_output(CveScanner::CveAnalystAgent, garbage)
      expect {
        CveScanner.call_agent_json(CveScanner::CveAnalystAgent, "prompt", scan_id: 1)
      }.not_to raise_error
    end
  end

  # ---------------------------------------------------------------------------
  # TC-05: scan_id nil — no broadcast, just returns the parsed hash.
  # ---------------------------------------------------------------------------
  describe "TC-05: scan_id nil — no broadcast" do
    let(:json_str) { '{"decision":"done","vulnerability_status":{}}' }

    it "returns parsed hash without broadcasting" do
      stub_agent_output(CveScanner::CveAnalystAgent, json_str)
      result = CveScanner.call_agent_json(CveScanner::CveAnalystAgent, "prompt", scan_id: nil)
      expect(result["decision"]).to eq("done")
      expect(broadcasts).to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # TC-06: role label appears in chat_turn_start and chat_turn_done broadcasts.
  # ---------------------------------------------------------------------------
  describe "TC-06: role is propagated to broadcasts" do
    let(:json_str) { '{"decision":"done","vulnerability_status":{}}' }

    it "uses the specified role in both events" do
      stub_agent_output(CveScanner::CveAnalystAgent, json_str)
      CveScanner.call_agent_json(CveScanner::CveAnalystAgent, "prompt",
                                 scan_id: 99, role: "CveAnalyst")
      start_event = broadcasts.find { |b| b[:type] == "chat_turn_start" }
      done_event  = broadcasts.find { |b| b[:type] == "chat_turn_done" }
      expect(start_event[:role]).to eq("CveAnalyst")
      expect(done_event[:role]).to eq("CveAnalyst")
    end
  end

  # ---------------------------------------------------------------------------
  # TC-07: CVE_SCANNER_MOCK_LLM=1 — returns deterministic fixed responses
  #        without calling the real LLM agent at all.
  # ---------------------------------------------------------------------------
  describe "TC-07: mock mode (CVE_SCANNER_MOCK_LLM set)" do
    around do |example|
      ClimateControl.modify(CVE_SCANNER_MOCK_LLM: "1") { example.run }
    end

    it "does not instantiate the agent class" do
      expect(CveScanner::CveAnalystAgent).not_to receive(:new)
      CveScanner.call_agent_json(CveScanner::CveAnalystAgent,
                                 "Analyse CVE-2023-52160.", scan_id: nil)
    end

    it "returns done with vulnerability_status keyed by CVE IDs in the prompt" do
      result = CveScanner.call_agent_json(CveScanner::CveAnalystAgent,
                                          "Analyse CVE-2023-52160 and CVE-2024-00001.",
                                          scan_id: nil)
      expect(result["decision"]).to eq("done")
      expect(result["vulnerability_status"].keys).to contain_exactly("CVE-2023-52160", "CVE-2024-00001")
    end

    it "broadcasts chat_turn_start and chat_turn_done when scan_id is set" do
      CveScanner.call_agent_json(CveScanner::CveAnalystAgent,
                                 "Analyse CVE-2023-52160.", scan_id: 7)
      expect(broadcasts.map { |b| b[:type] }).to include("chat_turn_start", "chat_turn_done")
    end

    it "FollowupAgent returns answered" do
      result = CveScanner.call_agent_json(CveScanner::FollowupAgent,
                                          "Is this exploitable?", scan_id: nil)
      expect(result["decision"]).to eq("answered")
    end

    it "RemediationAdvisorAgent returns complete" do
      result = CveScanner.call_agent_json(CveScanner::RemediationAdvisorAgent,
                                          "Suggest fixes.", scan_id: nil)
      expect(result["decision"]).to eq("complete")
    end
  end
end
