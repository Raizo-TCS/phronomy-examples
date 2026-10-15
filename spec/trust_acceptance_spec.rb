# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require_relative "../scripts/support/trust_acceptance_observer"

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
