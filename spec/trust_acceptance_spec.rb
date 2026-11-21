# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require_relative "../scripts/support/trust_acceptance_observer"
require_relative "../scripts/support/trust_approval_acceptance"
require_relative "../19_trust_pipeline/llm_compatibility"

RSpec.describe "Trust pipeline acceptance diagnostics" do
  def run_case(name)
    original_args = ARGV.dup
    original_verbose = $VERBOSE
    $VERBOSE = nil
    Dir.mktmpdir("trust-acceptance-test-") do |dir|
      path = File.join(dir, "report.json")
      ARGV.replace(["--case", name, "--report", path, "--snapshot-interval", "0.05"])
      status = nil
      expect {
        load File.expand_path("../scripts/verify_trust_pipeline.rb", __dir__)
      }.to raise_error(SystemExit) { |error| status = error.status }
      [status, JSON.parse(File.read(path))]
    end
  ensure
    ARGV.replace(original_args)
    $VERBOSE = original_verbose
  end

  before do
    allow($stdout).to receive(:puts)
    allow($stderr).to receive(:puts)
  end

  it "preserves evidence from earlier trials instead of overwriting it" do
    Dir.mktmpdir("trust-report-test-") do |dir|
      path = File.join(dir, "previous.json")
      File.write(path, '{"status":"failed"}')
      expect { TrustAcceptanceObserver.new(path: path) }.to raise_error(Errno::EEXIST)
      expect(File.read(path)).to eq('{"status":"failed"}')
    end
  end

  it "records fidelity failure with release, the actual response and unchanged SDK settings" do
    chat = ExampleChatStub.new { '{"invoice_id":"INV-2026-01","total":1250}' }
    settings = [RubyLLM.config.request_timeout, RubyLLM.config.max_retries]
    status, report = run_case("invoice")
    expect(status).to eq(1)
    expect(report["status"]).to eq("failed")
    expect(report["webmock_loaded"]).to be true
    expect(report["releases"].last["value"]).to be true
    expect(report["responses"].to_s).to include("INV-2026-01")
    expect(report["requests"].length).to eq(1)
    expect(report["snapshots"].length).to be >= 2
    expect(report["requests"].first["sdk_settings"].values_at("request_timeout", "max_retries")).to eq(settings)
    expect([RubyLLM.config.request_timeout, RubyLLM.config.max_retries]).to eq(settings)
    expect(chat.calls.length).to eq(1)
  end

  it "accepts faithful extraction" do
    ExampleChatStub.new { '{"invoice_id":"INV-2026-001","total":1250}' }
    status, report = run_case("invoice")
    expect([status, report["status"]]).to eq([0, "passed"]), report["primary_error"].inspect
  end

  %w[accepted iteration_limit].each do |reason|
    it "checks #{reason} from valid draft/review results" do
      ExampleChatStub.new do |_body, index|
        if index.even?
          JSON.generate(answer: "Evidence unavailable", confidence: (reason == "accepted") ? 0.95 : 0.0, citations: [])
        else
          JSON.generate(approved: reason == "accepted", score: (reason == "accepted") ? 0.95 : 0.0, feedback: "Evidence checked")
        end
      end
      status, report = run_case(reason)
      expect([status, report["status"]]).to eq([0, "passed"])
      expect(report["results"].last.dig("value", "termination_reason")).to eq(reason)
    end
  end

  %w[yes no cancel].each do |answer|
    it "requires real approval progression for #{answer} (test provider explicitly stubbed)" do
      chat = ExampleChatStub.new do |_body, index|
        case index
        when 0 then ExampleChatStub.tool("approved_policy_lookup", query: "refund")
        when 1 then JSON.generate(answer: "Refund policy", confidence: 0.95, citations: [])
        else JSON.generate(approved: true, score: 0.95, feedback: "")
        end
      end
      status, report = run_case("approval-#{answer}")
      expect([status, report["status"]]).to eq([0, "passed"])
      expect(report["approvals"].length).to eq(1)
      expect(report["tool_executions"]).to eq((answer == "yes") ? 1 : 0)
      expect(chat.calls.length).to eq((answer == "yes") ? 3 : 1)
      expect(chat.calls.first.dig("response_format", "type")).to eq("json_schema")
      expect(chat.calls.first["tools"]).not_to be_empty
    end
  end

  %w[native tool_then_schema].each do |mode|
    %w[accepted iteration_limit].each do |reason|
      it "approves both distinct drafts after a rejected review in #{mode}, ending with #{reason}", :draft_contract do
        previous_mode = ENV[TrustLlmCompatibility::ENV_KEY]
        ENV[TrustLlmCompatibility::ENV_KEY] = mode
        chat = ExampleChatStub.new do |_body, index|
          case index % 3
          when 0 then ExampleChatStub.tool("approved_policy_lookup", query: "refund")
          when 1 then JSON.generate(answer: "Refund policy", confidence: 0.95, citations: [])
          else
            accepted = index == 5 && reason == "accepted"
            JSON.generate(approved: accepted, score: accepted ? 0.95 : 0.6, feedback: "Check the policy evidence")
          end
        end
        status, report = run_case("approval-yes")
        expect([status, report["status"]]).to eq([0, "passed"]), report.inspect
        expect(chat.calls.length).to eq(6)
        expect(report["approvals"].length).to eq(2)
        expect(report["decisions"].map { |item| item["approved"] }).to eq([true, true])
        expect(report["tool_executions"]).to eq(2)
        expect(report["tool_effects"].map { |item| item["tool_invocation_id"] }.uniq.length).to eq(2)
        expect(report["releases"].last["value"]).to be true
        result = report["results"].last.fetch("value")
        expect(result.values_at("termination_reason", "iterations")).to eq([reason, 2])

        # Both requests concern the same business question. Revision history must
        # not silently change the declared unit from one lookup per draft.
        [chat.calls[0], chat.calls[3]].each do |request|
          system = request.fetch("messages").find { |message| message["role"] == "system" }.fetch("content")
          expect(system).to include("Each draft request, including a revision, requires its own approved_policy_lookup call.")
          expect(system).to include("After the Tool result for the current draft arrives, answer from that result without another Tool call for that draft.")
          prompt = request.fetch("messages").last
          expect(prompt.fetch("role")).to eq("user")
          expect(prompt.fetch("content")).to include("Draft request for: What is the refund policy?",
            "Start a new approved_policy_lookup call for this draft, even when an earlier draft answered the same question.")
        end
        expect(chat.calls[0]["messages"].last["content"]).to include("Draft stage: initial")
        expect(chat.calls[3]["messages"].last["content"]).to include("Draft stage: revision", "Check the policy evidence")
        expect(chat.calls[3]["messages"].count { |message| message["role"] == "tool" }).to eq(1)

        # An unchanged total cannot hide executing the first approved invocation twice.
        duplicate_effect = Marshal.load(Marshal.dump(report))
        duplicate_effect["tool_effects"][1] = duplicate_effect["tool_effects"][0]
        expect(TrustApprovalAcceptance.yes?(duplicate_effect, result)).to be false
        missing_approval = Marshal.load(Marshal.dump(report))
        missing_approval["approvals"].pop
        expect(TrustApprovalAcceptance.yes?(missing_approval, result)).to be false
        wrong_decision = Marshal.load(Marshal.dump(report))
        wrong_decision["decisions"][1]["request_id"] = "unrelated-request"
        expect(TrustApprovalAcceptance.yes?(wrong_decision, result)).to be false
      ensure
        ENV[TrustLlmCompatibility::ENV_KEY] = previous_mode
      end
    end

    it "does not count the previous draft's lookup as the revision's lookup in #{mode}", :draft_contract do
      previous_mode = ENV[TrustLlmCompatibility::ENV_KEY]
      ENV[TrustLlmCompatibility::ENV_KEY] = mode
      chat = ExampleChatStub.new do |_body, index|
        case index
        when 0 then ExampleChatStub.tool("approved_policy_lookup", query: "refund")
        when 1, 3 then JSON.generate(answer: "Refund policy", confidence: 0.95, citations: [])
        when 2 then JSON.generate(approved: false, score: 0.6, feedback: "Check the policy evidence")
        when 4 then JSON.generate(approved: true, score: 0.95, feedback: "Revised answer verified")
        else raise "Unexpected additional request"
        end
      end
      status, report = run_case("approval-yes")
      expect([status, report["status"]]).to eq([1, "failed"])
      expect(report["approvals"].length).to eq(1)
      expect(report["decisions"].map { |item| item["approved"] }).to eq([true])
      expect(report["tool_executions"]).to eq(1)
      expect(report["releases"].last["value"]).to be true
      expect(chat.calls[3]["messages"].count { |message| message["role"] == "tool" }).to eq(1)
      if mode == "tool_then_schema"
        expect(chat.calls.length).to eq(4)
        expect(report["primary_error"].first).to include(
          "class" => "Phronomy::LLMAdapter::InvalidResultError",
          "message" => "Required approved_policy_lookup was not requested"
        )
      else
        expect(chat.calls.length).to eq(5)
        expect(report["results"].last.dig("value", "iterations")).to eq(2)
      end
    ensure
      ENV[TrustLlmCompatibility::ENV_KEY] = previous_mode
    end
  end

  it "bounds predetermined yes answers and retains one answer for denial or cancellation" do
    expect(TrustApprovalAcceptance.input("yes").each_line.to_a).to eq(["yes\n", "yes\n"])
    expect(TrustApprovalAcceptance.input("no").each_line.to_a).to eq(["no\n"])
    expect(TrustApprovalAcceptance.input("cancel").each_line.to_a).to eq(["cancel\n"])
  end

  it "reports schema-plus-Tool rejection as blocked, never as a successful approval" do
    stub_request(:post, %r{/chat/completions\z}).to_return(status: 400,
      headers: {"Content-Type" => "application/json"},
      body: JSON.generate(error: "Cannot combine structured output constraints with lazy grammar"))
    status, report = run_case("approval-yes")
    expect([status, report["status"]]).to eq([2, "blocked"])
    expect(report["approvals"]).to be_empty
    expect(report["tool_executions"]).to eq(0)
    expect(report["releases"].last["value"]).to be true
  end

  it "does not accept a model that skips the required Tool and approval" do
    ExampleChatStub.new do |_body, index|
      index.even? ? JSON.generate(answer: "Policy", confidence: 0.95, citations: []) :
        JSON.generate(approved: true, score: 0.95, feedback: "")
    end
    status, report = run_case("approval-yes")
    expect([status, report["status"]]).to eq([1, "failed"])
    expect(report["approvals"]).to be_empty
  end
end
