# frozen_string_literal: true

require "spec_helper"
require "webrick"
require "open3"
require "timeout"
require "json"

RSpec.describe "Example 07 explicit LM Studio composition" do
  let(:root) { File.expand_path("..", __dir__) }
  let(:engine_error) do
    {code: 500, type: "server_error",
     message: "The model produced output that does not match the expected peg-native format"}
  end
  let(:parse_failure) { {error: "Engine protocol predict stream returned an error: #{JSON.generate(engine_error)}"} }
  let(:success) do
    {id: "completion-1", object: "chat.completion", model: "openai/gpt-oss-20b",
     choices: [{index: 0, message: {role: "assistant", content: "package main\nfunc main() { println(\"Hello World\") }"}, finish_reason: "stop"}],
     usage: {prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}}
  end

  def run_with(responses)
    requests = []
    server = WEBrick::HTTPServer.new(BindAddress: "127.0.0.1", Port: 0,
      Logger: WEBrick::Log.new(File::NULL), AccessLog: [])
    server.mount_proc("/v1/chat/completions") do |request, response|
      requests << JSON.parse(request.body)
      status, body = responses.fetch([requests.length - 1, responses.length - 1].min)
      response.status = status
      response["Content-Type"] = "application/json"
      response.body = JSON.generate(body)
    end
    thread = Thread.new { server.start }
    env = {
      "BUNDLE_GEMFILE" => File.join(root, "Gemfile"),
      "PHRONOMY_BASE_URL" => "http://127.0.0.1:#{server.config[:Port]}/v1",
      "PHRONOMY_PROVIDER" => "openai", "PHRONOMY_MODEL" => "openai/gpt-oss-20b",
      "PHRONOMY_API_KEY" => "local-test-only", "PHRONOMY_CONTEXT_WINDOW" => "131072"
    }
    out, err, status = Timeout.timeout(20) do
      Open3.capture3(env, "bundle", "exec", "ruby", "07_tracing/run_lm_studio.rb", chdir: root)
    end
    [out, err, status, requests]
  ensure
    server&.shutdown
    thread&.value
  end

  it "succeeds with one POST and keeps one logical LLM call" do
    out, err, status, requests = run_with([[200, success]])
    expect(status.success?).to be(true), "#{out}\n#{err}"
    expect(requests.length).to eq(1)
    expect(out.scan(/\[SPAN START\] llm.call/).length).to eq(1)
    expect(out.scan(/\[SPAN END\]\s+llm.call/).length).to eq(1)
  end

  it "recovers once without replaying Agent or Workflow and retains the first failure warning" do
    out, err, status, requests = run_with([[400, parse_failure], [200, success]])
    expect(status.success?).to be(true), "#{out}\n#{err}"
    expect(requests.length).to eq(2)
    expect(requests[0]).to eq(requests[1])
    %w[llm.call agent.execution workflow.execution].each do |name|
      expect(out.scan(/\[SPAN START\] #{Regexp.escape(name)}/).length).to eq(1)
      expect(out.scan(/\[SPAN END\]\s+#{Regexp.escape(name)}/).length).to eq(1)
    end
    expect(err).to include("code=llm.provider_output_parse_failed", "http_status=400", "retrying=true")
  end

  it "fails after two known errors and preserves the safe failure record" do
    out, err, status, requests = run_with([[500, parse_failure]])
    expect(status.success?).to be(false), out
    expect(requests.length).to eq(2)
    expect(err).to include("attempt=1", "attempt=2", "retrying=false")
  end

  it "does not retry an unknown provider error" do
    _out, err, status, requests = run_with([[500, {error: "unknown error"}]])
    expect(status.success?).to be(false)
    expect(requests.length).to eq(1)
    expect(err).not_to include("code=llm.provider_output_parse_failed")
  end
end
