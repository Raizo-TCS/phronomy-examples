# frozen_string_literal: true

require "rails_helper"

# ---------------------------------------------------------------------------
# Tests for CveScanner state-graph node methods and end-to-end workflow
# state transitions.
#
# All LLM calls are stubbed via CveScanner.call_agent_json — real HTTP
# connections are never made. Shell commands (lsb_release, uname) and
# network scraping are also stubbed so the suite runs offline.
#
# Operation patterns covered:
#   PATH-A  propose_checks returns "done" immediately → report → followup wait
#   PATH-B  propose_checks returns "need_more" → check approval wait
#   PATH-B2 resume after approve → evaluate returns "done" → followup wait
#   PATH-B3 resume after skip (no commands) → loop continues → approval wait
#   PATH-C  all CVEs skipped in check_cve_data → goes direct to report
#   FU-1    followup "done" → workflow finishes
#   FU-2    followup "answered" → back to followup wait
#   FU-3    followup "reinvestigate" → resets state, gathers again
#   LOOP    check iteration limit reached → forced done without LLM call
#   NODE    individual node unit tests (node_check_cve_data, node_run_checks)
# ---------------------------------------------------------------------------

# Shared CVE info structure returned by the scraper stub.
FAKE_CVE_INFO = {
  priority: "medium",
  description: "A test vulnerability.",
  packages: {"wpasupplicant" => {status: "vulnerable", fixed_version: nil}},
  references: []
}.freeze

def fake_cve_infos(cve_id = "CVE-2023-52160")
  {cve_id => FAKE_CVE_INFO}
end

# Build a minimal ScanState pre-populated past the gather/check stages.
def state_after_gather(cve_id: "CVE-2023-52160")
  CveScanner::ScanState.new(
    cve_ids: [cve_id],
    os_version: "24.04",
    kernel_version: "6.17.0-23-generic",
    cve_infos: fake_cve_infos(cve_id),
    vulnerability_status: {},
    vulnerability_reasoning: {},
    check_iteration: 0,
    check_decision: nil,
    proposed_checks: [],
    approved_checks: [],
    check_history: [],
    messages: []
  )
end

# Stub call_agent_json for a specific agent class.
# responses: Array<Hash> — returned in order, last one repeated if list exhausted.
def stub_llm(agent_class, responses)
  call_count = 0
  allow(CveScanner).to receive(:call_agent_json).with(agent_class, anything, anything) do
    r = responses[call_count] || responses.last
    call_count += 1
    r.transform_keys(&:to_s)
  end
end

RSpec.describe "CveScanner scan graph" do
  before do
    # Suppress all ActionCable broadcasts — we only care about state mutations.
    allow(ScanChannel).to receive(:broadcast)
    # Stub OS detection shell commands used in node_gather_scan_info.
    allow(CveScanner::ScanGraph).to receive(:`).and_return("") if defined?(CveScanner::ScanGraph)
    # Stub scraper to avoid real HTTP calls.
    allow_any_instance_of(CveScanner::UbuntuCveScraperTool).to receive(:execute) do |_, cve_id:|
      FAKE_CVE_INFO.merge(cve_id: cve_id).to_json
    end
    # Stub command executor.
    allow_any_instance_of(CveScanner::CommandExecutorTool).to receive(:execute) do |_, command:|
      "Package: wpasupplicant\nStatus: installed\nVersion: 2:2.10-21ubuntu0.4"
    end
  end

  # =========================================================================
  # NODE-LEVEL TESTS
  # =========================================================================

  describe "node_check_cve_data" do
    context "when CVE info contains an error (not found)" do
      let(:state) do
        CveScanner::ScanState.new(
          cve_ids: ["CVE-9999-0001"],
          cve_infos: {"CVE-9999-0001" => {error: "error=404"}},
          vulnerability_status: {},
          messages: []
        )
      end

      it "marks the CVE as not_found and does not call the LLM" do
        expect(CveScanner).not_to receive(:call_agent_json)
        new_state = CveScanner.node_check_cve_data(state, scan_id: nil)
        expect(new_state.vulnerability_status["CVE-9999-0001"]).to eq("not_found")
      end
    end

    context "when CVE info has no packages" do
      let(:state) do
        CveScanner::ScanState.new(
          cve_ids: ["CVE-9999-0002"],
          cve_infos: {"CVE-9999-0002" => {priority: "low", packages: {}, description: "x"}},
          vulnerability_status: {},
          messages: []
        )
      end

      it "marks the CVE as no_packages" do
        new_state = CveScanner.node_check_cve_data(state, scan_id: nil)
        expect(new_state.vulnerability_status["CVE-9999-0002"]).to eq("no_packages")
      end
    end

    context "when CVE info has packages" do
      it "returns state unchanged (no pre-status set)" do
        state = state_after_gather
        new_state = CveScanner.node_check_cve_data(state, scan_id: nil)
        expect(new_state.vulnerability_status).to be_empty
      end
    end
  end

  describe "node_run_checks" do
    it "runs each approved command and records the output" do
      state = state_after_gather.merge(approved_checks: ["dpkg -s wpasupplicant"])
      new_state = CveScanner.node_run_checks(state, scan_id: nil)
      expect(new_state.check_history.last[:cmd]).to eq("dpkg -s wpasupplicant")
      expect(new_state.check_history.last[:output]).to include("wpasupplicant")
    end

    it "records nothing when approved_checks is empty" do
      state = state_after_gather.merge(approved_checks: [])
      new_state = CveScanner.node_run_checks(state, scan_id: nil)
      expect(new_state.check_history).to be_empty
    end
  end

  describe "node_propose_checks" do
    context "when LLM returns need_more" do
      it "sets check_decision to need_more and stores proposed commands" do
        state = state_after_gather
        stub_llm(CveScanner::CveAnalystAgent, [
          {decision: "need_more", proposed_commands: ["dpkg -s wpasupplicant"]}
        ])
        new_state = CveScanner.node_propose_checks(state, scan_id: nil)
        expect(new_state.check_decision).to eq("need_more")
        expect(new_state.proposed_checks).to eq(["dpkg -s wpasupplicant"])
      end
    end

    context "when LLM returns done" do
      it "sets check_decision to done and stores vulnerability_status" do
        state = state_after_gather
        stub_llm(CveScanner::CveAnalystAgent, [
          {decision: "done",
           vulnerability_status: {"CVE-2023-52160" => "vulnerable"},
           reasoning: {"CVE-2023-52160" => "affected version"}}
        ])
        new_state = CveScanner.node_propose_checks(state, scan_id: nil)
        expect(new_state.check_decision).to eq("done")
        expect(new_state.vulnerability_status["CVE-2023-52160"]).to eq("vulnerable")
      end
    end

    context "when iteration limit is reached" do
      it "forces done without calling the LLM" do
        state = state_after_gather.merge(
          check_iteration: CveScanner::MAX_LOOP_ITERATIONS,
          vulnerability_status: {"CVE-2023-52160" => "unknown"}
        )
        expect(CveScanner).not_to receive(:call_agent_json)
        new_state = CveScanner.node_propose_checks(state, scan_id: nil)
        expect(new_state.check_decision).to eq("done")
      end
    end
  end

  # =========================================================================
  # WORKFLOW END-TO-END TESTS (full graph traversal)
  # =========================================================================

  # Build the graph and stub node_gather_scan_info so OS / scraper calls are
  # bypassed while the graph itself is exercised.
  def build_stubbed_graph(scan_id: nil)
    allow(CveScanner).to receive(:node_gather_scan_info) do |state, **|
      state.merge(
        cve_ids: state.cve_ids,
        os_version: "24.04",
        kernel_version: "6.17.0-23-generic",
        cve_infos: fake_cve_infos(state.cve_ids.first || "CVE-2023-52160"),
        messages: ["OS: Ubuntu 24.04"]
      )
    end
    CveScanner.build_graph(scan_id: scan_id)
  end

  # Resume a halted graph from a persisted-like state.
  def resume_graph(graph, halted_state, updates = {})
    state = halted_state.merge(updates)
    graph.resume(state: state)
  end

  # -------------------------------------------------------------------------
  # PATH-A: LLM decides "done" on first propose_checks → halts at followup
  # -------------------------------------------------------------------------
  describe "PATH-A: propose_checks returns done immediately" do
    it "halts at awaiting_followup after report" do
      stub_llm(CveScanner::CveAnalystAgent, [
        {decision: "done",
         vulnerability_status: {"CVE-2023-52160" => "vulnerable"},
         reasoning: {"CVE-2023-52160" => "affected version installed"}}
      ])

      graph = build_stubbed_graph
      state = graph.invoke({cve_ids: ["CVE-2023-52160"]},
                           config: {thread_id: "test-path-a"})

      expect(state).to be_halted
      expect(state.phase).to eq(:awaiting_followup)
      expect(state.vulnerability_status["CVE-2023-52160"]).to eq("vulnerable")
    end
  end

  # -------------------------------------------------------------------------
  # PATH-B: LLM returns need_more → halts at awaiting_check_approval
  # -------------------------------------------------------------------------
  describe "PATH-B: propose_checks returns need_more" do
    it "halts at awaiting_check_approval with proposed commands" do
      stub_llm(CveScanner::CveAnalystAgent, [
        {decision: "need_more", proposed_commands: ["dpkg -s wpasupplicant"]}
      ])

      graph = build_stubbed_graph
      state = graph.invoke({cve_ids: ["CVE-2023-52160"]},
                           config: {thread_id: "test-path-b"})

      expect(state).to be_halted
      expect(state.phase).to eq(:awaiting_check_approval)
      expect(state.proposed_checks).to eq(["dpkg -s wpasupplicant"])
    end
  end

  # -------------------------------------------------------------------------
  # PATH-B2: approve → evaluate returns done → halts at awaiting_followup
  # -------------------------------------------------------------------------
  describe "PATH-B2: approve → evaluate done → followup wait" do
    it "runs the commands then halts at awaiting_followup" do
      # First call: propose → need_more. Second call: evaluate → done.
      stub_llm(CveScanner::CveAnalystAgent, [
        {decision: "need_more", proposed_commands: ["dpkg -s wpasupplicant"]},
        {decision: "done",
         vulnerability_status: {"CVE-2023-52160" => "vulnerable"},
         reasoning: {"CVE-2023-52160" => "version matches"}}
      ])

      graph = build_stubbed_graph
      halted = graph.invoke({cve_ids: ["CVE-2023-52160"]},
                            config: {thread_id: "test-path-b2"})
      expect(halted.phase).to eq(:awaiting_check_approval)

      resumed = resume_graph(graph, halted,
                             approved_checks: ["dpkg -s wpasupplicant"])

      expect(resumed).to be_halted
      expect(resumed.phase).to eq(:awaiting_followup)
      expect(resumed.vulnerability_status["CVE-2023-52160"]).to eq("vulnerable")
    end
  end

  # -------------------------------------------------------------------------
  # PATH-B3: skip (approve empty) → evaluate returns need_more → halts again
  # -------------------------------------------------------------------------
  describe "PATH-B3: skip commands → evaluate need_more → halt again" do
    it "loops back to awaiting_check_approval when user skips" do
      # First propose → need_more, second propose → need_more (after skip)
      stub_llm(CveScanner::CveAnalystAgent, [
        {decision: "need_more", proposed_commands: ["dpkg -s wpasupplicant"]},
        {decision: "need_more", proposed_commands: ["apt-cache policy wpasupplicant"]}
      ])

      graph = build_stubbed_graph
      halted = graph.invoke({cve_ids: ["CVE-2023-52160"]},
                            config: {thread_id: "test-path-b3"})
      expect(halted.phase).to eq(:awaiting_check_approval)

      # User approves nothing (skip)
      resumed = resume_graph(graph, halted, approved_checks: [])

      expect(resumed).to be_halted
      expect(resumed.phase).to eq(:awaiting_check_approval)
      expect(resumed.proposed_checks).to eq(["apt-cache policy wpasupplicant"])
    end
  end

  # -------------------------------------------------------------------------
  # PATH-C: all CVEs not found / no packages → skips directly to report
  # -------------------------------------------------------------------------
  describe "PATH-C: all CVEs have no package data → skip to report" do
    it "halts at awaiting_followup without calling the analyst" do
      allow(CveScanner).to receive(:node_gather_scan_info) do |state, **|
        state.merge(
          cve_ids: state.cve_ids,
          os_version: "24.04",
          kernel_version: "6.17.0-23-generic",
          cve_infos: {"CVE-9999-0001" => {error: "error=404"}},
          messages: []
        )
      end
      expect(CveScanner).not_to receive(:call_agent_json)

      graph = CveScanner.build_graph(scan_id: nil)
      state = graph.invoke({cve_ids: ["CVE-9999-0001"]},
                           config: {thread_id: "test-path-c"})

      expect(state).to be_halted
      expect(state.phase).to eq(:awaiting_followup)
      expect(state.vulnerability_status["CVE-9999-0001"]).to eq("not_found")
    end
  end

  # -------------------------------------------------------------------------
  # FU-1: followup "done" keyword → short-circuits LLM, workflow finishes
  # -------------------------------------------------------------------------
  describe "FU-1: followup done keyword → workflow finishes without LLM call" do
    it "returns a non-halted final state and does not call FollowupAgent" do
      stub_llm(CveScanner::CveAnalystAgent, [
        {decision: "done",
         vulnerability_status: {"CVE-2023-52160" => "vulnerable"},
         reasoning: {}}
      ])
      # FollowupAgent must NOT be called for the "done" keyword.
      expect(CveScanner).not_to receive(:call_agent_json)
        .with(CveScanner::FollowupAgent, anything, anything)

      graph = build_stubbed_graph
      halted = graph.invoke({cve_ids: ["CVE-2023-52160"]},
                            config: {thread_id: "test-fu1"})
      expect(halted.phase).to eq(:awaiting_followup)

      final = resume_graph(graph, halted, followup_request: "done")

      expect(final).not_to be_halted
    end

    it "broadcasts followup_answer (not chat_turn_done) with decision: done" do
      stub_llm(CveScanner::CveAnalystAgent, [
        {decision: "done", vulnerability_status: {"CVE-2023-52160" => "vulnerable"}, reasoning: {}}
      ])
      broadcasts = []
      allow(ScanChannel).to receive(:broadcast) { |_id, payload| broadcasts << payload }

      graph = build_stubbed_graph(scan_id: 1)
      halted = graph.invoke({cve_ids: ["CVE-2023-52160"]},
                            config: {thread_id: "test-fu1-broadcast"})
      broadcasts.clear
      resume_graph(graph, halted, followup_request: "done")

      farewell_event = broadcasts.find { |b| b[:type] == "followup_answer" && b[:decision] == "done" }
      expect(farewell_event).not_to be_nil
      expect(farewell_event[:answer]).to include("Session ended")
      # Must NOT broadcast chat_turn_done for this path.
      expect(broadcasts.none? { |b| b[:type] == "chat_turn_done" }).to be true
    end

    it "also short-circuits for other done synonyms (exit, quit, finish)" do
      stub_llm(CveScanner::CveAnalystAgent, [
        {decision: "done", vulnerability_status: {}, reasoning: {}}
      ])

      %w[exit quit finish].each do |keyword|
        graph = build_stubbed_graph
        halted = graph.invoke({cve_ids: ["CVE-2023-52160"]},
                              config: {thread_id: "test-fu1-#{keyword}"})
        final = resume_graph(graph, halted, followup_request: keyword)
        expect(final).not_to be_halted, "expected done for keyword '#{keyword}'"
      end
    end
  end

  # -------------------------------------------------------------------------
  # FU-2: followup "answered" → halts at awaiting_followup again
  # -------------------------------------------------------------------------
  describe "FU-2: followup answered → back to awaiting_followup" do
    it "halts again at awaiting_followup" do
      stub_llm(CveScanner::CveAnalystAgent, [
        {decision: "done", vulnerability_status: {"CVE-2023-52160" => "vulnerable"}, reasoning: {}}
      ])
      stub_llm(CveScanner::FollowupAgent, [
        {decision: "answered", answer: "Here is the explanation."}
      ])

      graph = build_stubbed_graph
      halted = graph.invoke({cve_ids: ["CVE-2023-52160"]},
                            config: {thread_id: "test-fu2"})

      resumed = resume_graph(graph, halted,
                             followup_request: "What does this mean?")

      expect(resumed).to be_halted
      expect(resumed.phase).to eq(:awaiting_followup)
    end
  end

  # -------------------------------------------------------------------------
  # FU-3: followup "reinvestigate" → state resets, gathers again
  # -------------------------------------------------------------------------
  describe "FU-3: followup reinvestigate → restarts scan" do
    it "resets check state and halts at awaiting_followup after second pass" do
      call_count = 0
      allow(CveScanner).to receive(:call_agent_json) do |agent_class, _, **|
        call_count += 1
        if agent_class == CveScanner::FollowupAgent
          {"decision" => "reinvestigate", "answer" => ""}
        else
          # First analyst pass → done. After reinvestigate, second pass → done again.
          {"decision" => "done",
           "vulnerability_status" => {"CVE-2023-52160" => "vulnerable"},
           "reasoning" => {}}
        end
      end

      graph = build_stubbed_graph
      halted = graph.invoke({cve_ids: ["CVE-2023-52160"]},
                            config: {thread_id: "test-fu3"})
      expect(halted.phase).to eq(:awaiting_followup)

      resumed = resume_graph(graph, halted, followup_request: "check again")

      # After reinvestigate the graph gathers data again and halts at followup.
      expect(resumed).to be_halted
      expect(resumed.phase).to eq(:awaiting_followup)
      # check_iteration reset and a fresh pass completed
      expect(resumed.check_iteration).to be >= 1
    end
  end

  # =========================================================================
  # normalize_vuln_status UNIT TESTS
  # =========================================================================

  describe "normalize_vuln_status" do
    context "when LLM returns all expected CVE IDs correctly" do
      it "returns the status unchanged" do
        raw = {"CVE-2023-52160" => "vulnerable"}
        result = CveScanner.normalize_vuln_status(raw, ["CVE-2023-52160"])
        expect(result).to eq({"CVE-2023-52160" => "vulnerable"})
      end
    end

    context "when LLM returns a corrupted CVE key" do
      it "sets the expected CVE to 'unknown'" do
        raw = {"VEC-2023521-60" => "vulnerable"}  # mangled key
        result = CveScanner.normalize_vuln_status(raw, ["CVE-2023-52160"])
        expect(result["CVE-2023-52160"]).to eq("unknown")
      end

      it "does not include the corrupted key in the output" do
        raw = {"VEC-2023521-60" => "vulnerable"}
        result = CveScanner.normalize_vuln_status(raw, ["CVE-2023-52160"])
        expect(result.keys).not_to include("VEC-2023521-60")
      end

      it "broadcasts a warning when scan_id is set" do
        broadcasts = []
        allow(ScanChannel).to receive(:broadcast) { |_id, payload| broadcasts << payload }
        raw = {"VEC-2023521-60" => "vulnerable"}
        CveScanner.normalize_vuln_status(raw, ["CVE-2023-52160"], scan_id: 1)
        warning = broadcasts.find { |b| b[:type] == "log" && b[:message].include?("WARNING") }
        expect(warning).not_to be_nil
        expect(warning[:message]).to include("VEC-2023521-60")
      end
    end

    context "when LLM omits a CVE entirely" do
      it "fills the missing CVE with 'unknown'" do
        raw = {"CVE-2023-52160" => "vulnerable"}  # CVE-2024-00001 absent
        result = CveScanner.normalize_vuln_status(raw, ["CVE-2023-52160", "CVE-2024-00001"])
        expect(result["CVE-2024-00001"]).to eq("unknown")
        expect(result["CVE-2023-52160"]).to eq("vulnerable")
      end
    end

    context "when LLM returns nil" do
      it "sets all CVEs to 'unknown' without raising" do
        result = CveScanner.normalize_vuln_status(nil, ["CVE-2023-52160"])
        expect(result).to eq({"CVE-2023-52160" => "unknown"})
      end
    end
  end

  # =========================================================================
  # MOCK MODE END-TO-END TEST
  # =========================================================================

  describe "MOCK: CVE_SCANNER_MOCK_LLM mode — full workflow without real LLM" do
    around do |example|
      ClimateControl.modify(CVE_SCANNER_MOCK_LLM: "1") { example.run }
    end

    it "reaches awaiting_followup and returns correct CVE keys" do
      graph = build_stubbed_graph
      state = graph.invoke({cve_ids: ["CVE-2023-52160"]},
                           config: {thread_id: "test-mock"})

      expect(state).to be_halted
      expect(state.phase).to eq(:awaiting_followup)
      expect(state.vulnerability_status.keys).to include("CVE-2023-52160")
      expect(state.vulnerability_status["CVE-2023-52160"]).to eq("vulnerable")
    end

    it "followup 'done' ends the session" do
      graph = build_stubbed_graph
      halted = graph.invoke({cve_ids: ["CVE-2023-52160"]},
                            config: {thread_id: "test-mock-done"})
      final = resume_graph(graph, halted, followup_request: "done")

      expect(final).not_to be_halted
    end

    it "followup question returns answered and halts at awaiting_followup again" do
      graph = build_stubbed_graph
      halted = graph.invoke({cve_ids: ["CVE-2023-52160"]},
                            config: {thread_id: "test-mock-fu"})
      resumed = resume_graph(graph, halted, followup_request: "Is this exploitable?")

      expect(resumed).to be_halted
      expect(resumed.phase).to eq(:awaiting_followup)
    end
  end

  # =========================================================================
  # SECOND-ROUND CHECK LOOP TESTS
  # These mirror PATH-B / PATH-B2 / PATH-B3 but add a second iteration.
  # =========================================================================

  # -------------------------------------------------------------------------
  # PATH-B4: R1 approve+run → evaluate need_more → R2 propose → halt again
  #          Analogous to PATH-B, but at the second iteration.
  # -------------------------------------------------------------------------
  describe "PATH-B4: two rounds — halts at check approval after R2 propose" do
    it "re-halts at awaiting_check_approval with R2 proposed commands" do
      stub_llm(CveScanner::CveAnalystAgent, [
        # R1: propose → need_more
        {decision: "need_more", proposed_commands: ["dpkg -s wpasupplicant"]},
        # R1: evaluate → need_more (triggers round 2)
        {decision: "need_more", proposed_commands: []},
        # R2: propose → need_more again
        {decision: "need_more", proposed_commands: ["apt-cache policy wpasupplicant"]}
      ])

      graph = build_stubbed_graph
      halted1 = graph.invoke({cve_ids: ["CVE-2023-52160"]},
                             config: {thread_id: "test-path-b4"})
      expect(halted1.phase).to eq(:awaiting_check_approval)
      expect(halted1.check_iteration).to eq(1)

      # Approve R1 commands → run → evaluate need_more → propose R2 → halt
      halted2 = resume_graph(graph, halted1, approved_checks: ["dpkg -s wpasupplicant"])

      expect(halted2).to be_halted
      expect(halted2.phase).to eq(:awaiting_check_approval)
      expect(halted2.proposed_checks).to eq(["apt-cache policy wpasupplicant"])
      expect(halted2.check_iteration).to eq(2)
    end
  end

  # -------------------------------------------------------------------------
  # PATH-B5: R1 + R2 both approved — evaluates done on R2 → followup
  #          Analogous to PATH-B2, but with two full rounds of commands.
  # -------------------------------------------------------------------------
  describe "PATH-B5: two full rounds of checks — done on R2 evaluation" do
    it "runs two rounds of commands then halts at awaiting_followup" do
      stub_llm(CveScanner::CveAnalystAgent, [
        # R1: propose → need_more
        {decision: "need_more", proposed_commands: ["dpkg -s wpasupplicant"]},
        # R1: evaluate → need_more (triggers round 2)
        {decision: "need_more", proposed_commands: []},
        # R2: propose → need_more
        {decision: "need_more", proposed_commands: ["apt-cache policy wpasupplicant"]},
        # R2: evaluate → done
        {decision: "done",
         vulnerability_status: {"CVE-2023-52160" => "vulnerable"},
         reasoning: {"CVE-2023-52160" => "version confirmed after 2 rounds"}}
      ])

      graph = build_stubbed_graph
      halted1 = graph.invoke({cve_ids: ["CVE-2023-52160"]},
                             config: {thread_id: "test-path-b5"})
      expect(halted1.phase).to eq(:awaiting_check_approval)

      # Approve R1 → evaluate need_more → propose R2 → halt
      halted2 = resume_graph(graph, halted1, approved_checks: ["dpkg -s wpasupplicant"])
      expect(halted2.phase).to eq(:awaiting_check_approval)
      expect(halted2.check_iteration).to eq(2)

      # Approve R2 → evaluate done → report → followup
      final = resume_graph(graph, halted2, approved_checks: ["apt-cache policy wpasupplicant"])

      expect(final).to be_halted
      expect(final.phase).to eq(:awaiting_followup)
      expect(final.vulnerability_status["CVE-2023-52160"]).to eq("vulnerable")
      expect(final.check_iteration).to eq(2)
    end
  end

  # -------------------------------------------------------------------------
  # PATH-B6: R1 skip → evaluate need_more → R2 approve+run → evaluate done
  #          Analogous to PATH-B3 + PATH-B2 combined (skip once, then approve).
  # -------------------------------------------------------------------------
  describe "PATH-B6: skip R1 then approve R2 — done on R2 evaluation" do
    it "halts at followup after R1 skip and R2 full approval" do
      stub_llm(CveScanner::CveAnalystAgent, [
        # R1: propose → need_more
        {decision: "need_more", proposed_commands: ["dpkg -s wpasupplicant"]},
        # R2: propose → need_more (after skip, evaluate calls no LLM, goes back to propose)
        {decision: "need_more", proposed_commands: ["apt-cache policy wpasupplicant"]},
        # R2: evaluate → done
        {decision: "done",
         vulnerability_status: {"CVE-2023-52160" => "not_vulnerable"},
         reasoning: {"CVE-2023-52160" => "patched version installed"}}
      ])

      graph = build_stubbed_graph
      halted1 = graph.invoke({cve_ids: ["CVE-2023-52160"]},
                             config: {thread_id: "test-path-b6"})
      expect(halted1.phase).to eq(:awaiting_check_approval)

      # R1: skip (approve nothing) → evaluate need_more (no LLM) → propose R2 → halt
      halted2 = resume_graph(graph, halted1, approved_checks: [])
      expect(halted2.phase).to eq(:awaiting_check_approval)
      expect(halted2.proposed_checks).to eq(["apt-cache policy wpasupplicant"])

      # R2: approve → run → evaluate done → report → followup
      final = resume_graph(graph, halted2, approved_checks: ["apt-cache policy wpasupplicant"])

      expect(final).to be_halted
      expect(final.phase).to eq(:awaiting_followup)
      expect(final.vulnerability_status["CVE-2023-52160"]).to eq("not_vulnerable")
    end
  end

  # -------------------------------------------------------------------------
  # LOOP: MAX_LOOP_ITERATIONS forces "done" without an LLM call
  # -------------------------------------------------------------------------
  describe "LOOP: iteration limit forces done" do
    it "exits the check loop when MAX_LOOP_ITERATIONS is reached" do
      # LLM always returns need_more — loop guard must terminate it.
      allow(CveScanner).to receive(:call_agent_json)
        .with(CveScanner::CveAnalystAgent, anything, anything)
        .and_return({"decision" => "need_more",
                     "proposed_commands" => ["dpkg -s wpasupplicant"]})

      # Simulate arriving at propose_checks at the limit boundary.
      state = state_after_gather.merge(
        check_iteration: CveScanner::MAX_LOOP_ITERATIONS - 1,
        vulnerability_status: {"CVE-2023-52160" => "unknown"}
      )

      new_state = CveScanner.node_propose_checks(state, scan_id: nil)
      expect(new_state.check_decision).to eq("done")
      # LLM should NOT have been called (limit guard fires first).
      expect(CveScanner).not_to have_received(:call_agent_json)
    end
  end
end
