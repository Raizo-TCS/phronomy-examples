# frozen_string_literal: true

require "spec_helper"
require "json"
require "open3"
require "timeout"
require "tmpdir"
require "webrick"

RSpec.describe "CLI verification evidence" do
  let(:root) { File.expand_path("..", __dir__) }

  def run_gate(base:, reports:, name:, limit: 5, env: {})
    script = <<~BASH
      set -euo pipefail
      BASE_DIR="$1"; SCRIPT_DIR="$2"; CLI_REPORT_ROOT="$3"
      CLI_KILL_GRACE_SECONDS=0.5; CLI_SNAPSHOT_INTERVAL_SECONDS=0.05
      declare -A EXAMPLE_TIMEOUTS EXAMPLE_ARGS
      EXAMPLE_TIMEOUTS["$4"]="$5"
      failed=0
      header() { :; }
      pass() { echo "PASS: $1"; }
      fail() { echo "FAIL: $1"; failed=1; }
      skip() { echo "SKIP: $1"; }
      source "$SCRIPT_DIR/verification_cli.sh"
      verify_cli_run "$4"
      exit "$failed"
    BASH
    output = Timeout.timeout(25) do
      Open3.capture3({"BUNDLE_GEMFILE" => File.join(root, "Gemfile")}.merge(env),
        "bash", "-c", script, "cli-test", base, File.join(root, "scripts"), reports, name, limit.to_s)
    end
    evidence = Dir.glob(File.join(reports, "cli-*", "execution.json")).fetch(0)
    [*output, JSON.parse(File.read(evidence)), File.dirname(evidence)]
  end

  def with_cli(source)
    Dir.mktmpdir("cli-verification-") do |dir|
      FileUtils.mkdir_p(File.join(dir, "fixture"))
      File.write(File.join(dir, "fixture/run.rb"), source)
      yield dir
    end
  end

  it "preserves complete stdout and stderr on success with private evidence files" do
    with_cli('puts "stdout"; warn "stderr"') do |dir|
      out, err, status, record, evidence = run_gate(base: dir, reports: dir, name: "fixture")
      expect(status.success?).to be(true), "#{out}\n#{err}"
      expect(record.values_at("status", "exit_code")).to eq(["completed", 0])
      expect(File.read(record.fetch("stdout"))).to eq("stdout\n")
      expect(File.read(record.fetch("stderr"))).to eq("stderr\n")
      expect(File.stat(evidence).mode & 0o777).to eq(0o700)
      Dir.glob(File.join(evidence, "*")).each { |path| expect(File.stat(path).mode & 0o777).to eq(0o600) }
    end
  end

  it "retains the entire failing log and original exit code" do
    with_cli('puts "start"; warn "failure" * 500; exit 7') do |dir|
      out, _err, status, record = run_gate(base: dir, reports: dir, name: "fixture")
      expect(status.success?).to be(false)
      expect(out).to include("exit 7", "evidence:")
      expect(record.values_at("status", "exit_code")).to eq(["failed", 7])
      expect(File.read(record.fetch("stderr"))).to eq("failure" * 500 + "\n")
    end
  end

  it "keeps an outer cutoff failed even when the child handles TERM and exits zero" do
    with_cli('$stdout.sync = true; trap("TERM") { exit 0 }; puts "waiting"; sleep 60') do |dir|
      out, _err, status, record = run_gate(base: dir, reports: dir, name: "fixture", limit: 2)
      expect(status.success?).to be(false)
      expect(out).to include("outer cutoff", "SDK timeout/cleanup not implied")
      expect(record.values_at("status", "exit_code")).to eq(["outer_cutoff", 124])
      expect(File.read(record.fetch("stdout"))).to eq("waiting\n")
    end
  end

  it "bounds a child that ignores TERM and retains its partial output" do
    with_cli('$stdout.sync = true; trap("TERM", "IGNORE"); puts "waiting"; sleep 60') do |dir|
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      out, _err, status, record = run_gate(base: dir, reports: dir, name: "fixture", limit: 2)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 10
      expect(status.success?).to be(false)
      expect(out).to include("cleanup unconfirmed")
      expect(record.values_at("status", "exit_code")).to eq(["killed", 137])
      expect(File.read(record.fetch("stdout"))).to eq("waiting\n")
    end
  end

  def with_http(stall_after: nil)
    requests = []
    gate = Queue.new
    server = WEBrick::HTTPServer.new(BindAddress: "127.0.0.1", Port: 0,
      Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
    server.mount_proc("/v1/chat/completions") do |request, response|
      payload = JSON.parse(request.body)
      requests << payload
      gate.pop if stall_after && requests.length > stall_after
      schema = payload.fetch("response_format").fetch("json_schema").fetch("schema")
      value = if schema.fetch("properties").key?("approved")
        {approved: true, score: 0.95, feedback: "Controlled HTTP review"}
      else
        {answer: "Controlled HTTP answer", confidence: 0.95, citations: []}
      end
      response["Content-Type"] = "application/json"
      response.body = JSON.generate(id: "cli-fixture", object: "chat.completion", model: "cli-fixture",
        choices: [{index: 0, message: {role: "assistant", content: JSON.generate(value)}, finish_reason: "stop"}],
        usage: {prompt_tokens: 10, completion_tokens: 5, total_tokens: 15})
    end
    thread = Thread.new { server.start }
    env = {"PHRONOMY_MODEL" => "cli-fixture", "PHRONOMY_PROVIDER" => "openai",
           "PHRONOMY_BASE_URL" => "http://127.0.0.1:#{server.config.fetch(:Port)}/v1",
           "PHRONOMY_API_KEY" => "test-only", "PHRONOMY_CONTEXT_WINDOW" => "8192",
           "PHRONOMY_MODEL_CAPABILITIES" => "function_calling,streaming,structured_output",
           "PHRONOMY_SERVER_VERSION" => "controlled-http-not-a-live-model"}
    Dir.mktmpdir("cli-http-evidence-") { |dir| yield env, dir, requests }
  ensure
    10.times { gate << true } if gate
    server&.shutdown
    thread&.join
  end

  it "observes all three CLI scenarios without changing SDK settings or approval acceptance" do
    with_http do |env, dir, requests|
      out, err, status, record = run_gate(base: root, reports: dir, name: "19_trust_pipeline", limit: 15, env: env)
      expect(status.success?).to be(true), "#{out}\n#{err}"
      report = JSON.parse(File.read(record.fetch("observation")))
      expect(report.values_at("status", "all_observed_pipelines_released", "webmock_loaded")).to eq(["completed", true, false])
      expect(requests.length).to eq(6)
      expect(report.fetch("requests").length).to eq(6)
      expect(report.fetch("http_attempts").length).to eq(6)
      expect(report.fetch("responses").length).to eq(6)
      expect(report.fetch("pipelines").length).to eq(3)
      expect(report.fetch("results").length).to eq(3)
      expect(report.fetch("requests").map { |r| r.fetch("sdk_settings").values_at("request_timeout", "max_retries") }).to all(eq([300, 3]))
      expect(report.fetch("observer_errors")).to be_empty
    end
  end

  it "retains the pending request and Ruby stack at cutoff, without mistaking an earlier release for full cleanup" do
    with_http(stall_after: 2) do |env, dir, _requests|
      out, err, status, record = run_gate(base: root, reports: dir, name: "19_trust_pipeline", limit: 5, env: env)
      expect(status.success?).to be(false), "#{out}\n#{err}"
      expect(record.fetch("exit_code")).to be_between(124, 137)
      report = JSON.parse(File.read(record.fetch("observation")))
      expect(report.fetch("requests").length).to eq(3)
      expect(report.fetch("responses").length).to eq(2)
      expect(report.fetch("pipelines").length).to eq(2)
      expect(report.fetch("releases")).to include(include("value" => true))
      expect(report["all_observed_pipelines_released"]).not_to be(true)
      expect(report.fetch("snapshots").length).to be > 2
      stacks = report.fetch("snapshots").flat_map { |s| s.fetch("threads").flat_map { |t| t["backtrace"] || [] } }
      expect(stacks.join("\n")).to match(%r{net/(?:http|protocol)})
      expect(File.read(record.fetch("stdout"))).to include("Question:", "Accepted: true")
      expect(report.fetch("observer_errors")).to be_empty
    end
  end

  it "records an SDK timeout and its original cause with cleanup, independently of an outer cutoff" do
    with_http(stall_after: 0) do |env, dir, _requests|
      preload = File.join(dir, "diagnostic-settings.rb")
      File.write(preload, 'require "ruby_llm"; RubyLLM.configure { |c| c.request_timeout = 0.2; c.max_retries = 0 }')
      path = File.join(dir, "observation.json")
      out, err, status = Timeout.timeout(15) do
        Open3.capture3(env, "bundle", "exec", "ruby", "-r", preload, "scripts/observe_trust_cli.rb",
          "--report", path, "--snapshot-interval", "0.05", chdir: root)
      end
      expect(status.success?).to be(false), "#{out}\n#{err}"
      report = JSON.parse(File.read(path))
      expect(report.values_at("status", "all_observed_pipelines_released")).to eq(["failed", true])
      classes = report.fetch("primary_error").map { |item| item.fetch("class") }
      expect(classes).to include("Phronomy::LLMAdapter::TransportError", "Faraday::TimeoutError")
      expect(report.fetch("http_attempts").length).to eq(1)
      expect(report.fetch("requests").first.fetch("sdk_settings").values_at("request_timeout", "max_retries")).to eq([0.2, 0])
    end
  end
end
