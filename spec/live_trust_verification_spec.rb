# frozen_string_literal: true

require "spec_helper"
require "json"
require "open3"
require "timeout"
require "webrick"

RSpec.describe "Live trust acceptance verification wiring" do
  let(:root) { File.expand_path("..", __dir__) }
  let(:helper) { File.join(root, "scripts/verification_trust.sh") }

  def run_gate(env = {}, live: true, omit_examples: false)
    script = <<~BASH
      set -euo pipefail
      BASE_DIR="$1"
      WITH_LLM="$3"
      PASS=0; FAIL=0; SKIP=0
      header() { echo "$1"; }
      pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
      fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
      skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }
      if [[ "$4" == true ]]; then
        # Simulate a successful RSpec invocation that executed no cases.
        # The independent summary check must reject the empty coverage.
        bundle() {
          if [[ "${2:-}" == rspec ]]; then return 0; fi
          command bundle "$@"
        }
      fi
      source "$2"
      verify_live_trust_acceptance
      echo "GATE pass=$PASS fail=$FAIL skip=$SKIP"
      [[ $FAIL -eq 0 ]]
    BASH
    out, err, status = Timeout.timeout(90) do
      Open3.capture3(env, "bash", "-c", script, "live-trust-test", root, helper, live.to_s, omit_examples.to_s)
    end
    path = out[/Trust acceptance reports: (.+)$/, 1]
    summary = path && JSON.parse(File.read(File.join(path, "summary.json")))
    [out, err, status, summary]
  end

  def with_controlled_http(variant, provider: "openai")
    requests = []
    headers = []
    api_path = (provider == "azure") ? "/openai/v1" : "/v1"
    server = WEBrick::HTTPServer.new(BindAddress: "127.0.0.1", Port: 0,
      Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
    server.mount_proc("#{api_path}/chat/completions") do |request, response|
      payload = JSON.parse(request.body)
      requests << payload
      headers << {"api-key" => request["api-key"], "authorization" => request["authorization"]}
      response["Content-Type"] = "application/json"
      if variant == :unsupported && !Array(payload["tools"]).empty? && payload["response_format"]
        response.status = 400
        response.body = JSON.generate(error: "Cannot combine structured output constraints with lazy grammar")
        next
      end

      properties = payload.dig("response_format", "json_schema", "schema", "properties") || {}
      missing = payload.fetch("messages").to_json.include?("fictional missing region Z")
      message = {role: "assistant"}
      if properties.key?("invoice_id")
        value = {invoice_id: (variant == :wrong_invoice) ? "INV-2026-01" : "INV-2026-001", total: 1250}
      elsif properties.key?("approved")
        value = {approved: !missing, score: missing ? 0.0 : 0.95, feedback: "Fixture review"}
      elsif !Array(payload["tools"]).empty? && payload["messages"].none? { |item| item["role"] == "tool" }
        value = nil
        message[:tool_calls] = [{id: "fixture-lookup", type: "function",
                                 function: {name: "approved_policy_lookup", arguments: '{"query":"refund"}'}}]
      else
        value = {answer: "Controlled HTTP fixture", confidence: missing ? 0.0 : 0.95, citations: []}
      end
      message[:content] = value && JSON.generate(value)
      response.body = JSON.generate(id: "controlled-http", object: "chat.completion", model: "live-suite-fixture",
        choices: [{index: 0, message: message, finish_reason: message[:tool_calls] ? "tool_calls" : "stop"}],
        usage: {prompt_tokens: 10, completion_tokens: 5, total_tokens: 15})
    end
    thread = Thread.new { server.start }
    env = {"PHRONOMY_MODEL" => "live-suite-fixture", "PHRONOMY_PROVIDER" => provider,
           "PHRONOMY_BASE_URL" => "http://127.0.0.1:#{server.config.fetch(:Port)}#{api_path}",
           "PHRONOMY_API_KEY" => "test-only", "PHRONOMY_CONTEXT_WINDOW" => "8192",
           "PHRONOMY_MODEL_CAPABILITIES" => "function_calling,streaming,structured_output",
           "PHRONOMY_SERVER_VERSION" => "controlled-http-not-a-live-model"}
    yield env, requests, headers
  ensure
    server&.shutdown
    thread&.join
  end

  it "automatically executes all six cases with the caller's server and no SDK/provider stubs" do
    with_controlled_http(:valid) do |env, requests|
      out, err, status, summary = run_gate(env)
      expect(status.success?).to be(true), "#{out}\n#{err}"
      expect(out).to include("6 examples, 0 failures", "GATE pass=1 fail=0 skip=0")
      expect(summary.fetch("counts")).to eq("passed" => 6)
      expect(requests.length).to eq(10)
      summary.fetch("cases").each_value do |item|
        report = JSON.parse(File.read(item.fetch("report")))
        expect(report.fetch("model")).to eq("live-suite-fixture")
        expect(report.fetch("webmock_loaded")).to be(false)
        expect(report.fetch("requests").first.fetch("sdk_settings").values_at("request_timeout", "max_retries")).to eq([300, 3])
      end
    end
  end

  it "fails overall acceptance when all three approval cases are blocked" do
    with_controlled_http(:unsupported) do |env, _requests|
      out, err, status, summary = run_gate(env)
      expect(status.success?).to be(false), "#{out}\n#{err}"
      expect(out).to include("6 examples, 3 failures", "GATE pass=0 fail=1 skip=0", "BLOCKED")
      expect(summary.fetch("counts")).to eq("passed" => 3, "blocked" => 3)
      %w[approval-yes approval-no approval-cancel].each do |name|
        expect(summary.fetch("cases").fetch(name).fetch("exit_code")).to eq(2)
      end
    end
  end

  it "passes the same six cases with example 19's explicit adaptation on a combination-rejecting fixture" do
    with_controlled_http(:unsupported) do |env, requests|
      env["PHRONOMY_TRUST_LLM_MODE"] = "tool_then_schema"
      out, err, status, summary = run_gate(env)
      expect(status.success?).to be(true), "#{out}\n#{err}"
      expect(summary.fetch("counts")).to eq("passed" => 6)
      expect(requests.length).to eq(10)
      expect(requests).to all(satisfy { |body| Array(body["tools"]).empty? || body["response_format"].nil? })
      summary.fetch("cases").each_value do |item|
        report = JSON.parse(File.read(item.fetch("report")))
        expect(report["llm_compatibility_mode"]).to eq("tool_then_schema")
        expect(report["combined_tool_schema_requests"]).to eq(0)
        expect(report["webmock_loaded"]).to be(false)
        expect(report["observation_complete"]).to be(true)
      end
    end
  end

  it "runs all six cases through the selected Azure SDK provider and credentials" do
    with_controlled_http(:valid, provider: "azure") do |env, requests, headers|
      out, err, status, summary = run_gate(env)
      expect(status.success?).to be(true), "#{out}\n#{err}"
      expect(summary.fetch("counts")).to eq("passed" => 6)
      expect(requests.length).to eq(10)
      expect(headers).to all(eq("api-key" => "test-only", "authorization" => nil))
      summary.fetch("cases").each_value do |item|
        report = JSON.parse(File.read(item.fetch("report")))
        expect(report.fetch("provider")).to eq("azure")
        expect(report.fetch("webmock_loaded")).to be(false)
      end
    end
  end

  it "fails overall acceptance for a schema-valid but incorrect invoice" do
    with_controlled_http(:wrong_invoice) do |env, _requests|
      out, err, status, summary = run_gate(env)
      expect(status.success?).to be(false), "#{out}\n#{err}"
      expect(out).to include("6 examples, 1 failure", "GATE pass=0 fail=1 skip=0")
      expect(summary.fetch("counts")).to eq("failed" => 1, "passed" => 5)
    end
  end

  it "explicitly skips the six live cases in syntax-only mode" do
    out, err, status, summary = run_gate(live: false)
    expect(status.success?).to be(true), "#{out}\n#{err}"
    expect(out).to include("all 6 live trust acceptance cases not run", "GATE pass=0 fail=0 skip=1")
    expect(summary).to be_nil
  end

  it "rejects successful RSpec exit without evidence for all six cases" do
    out, _err, status, summary = run_gate(omit_examples: true)
    expect(status.success?).to be(false)
    expect(out).to include("GATE pass=0 fail=1 skip=0")
    expect(summary).to be_nil
  end
end
