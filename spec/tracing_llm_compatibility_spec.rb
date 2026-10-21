# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"
require_relative "../07_tracing/llm_compatibility"

RSpec.describe "Example 07 application-owned LLM compatibility" do
  def run_tracing(mode: "lmstudio_gpt_oss", response: "package main\nimport \"fmt\"\nfunc main() { fmt.Println(\"Hello, World!\") }", status: 200)
    source = <<~'RUBY'
      require "json"
      require "webmock"
      include WebMock::API
      WebMock.enable!
      WebMock.disable_net_connect!
      calls = []
      stub_request(:post, "https://example.test/v1/chat/completions").to_return do |request|
        calls << JSON.parse(request.body)
        body = if ENV.fetch("TEST_STATUS") == "200"
          {id: "chatcmpl-tracing", object: "chat.completion", created: 0,
           model: "openai/gpt-oss-20b", choices: [{index: 0, finish_reason: "stop",
             message: {role: "assistant", content: ENV.fetch("TEST_RESPONSE")}}],
           usage: {prompt_tokens: 92, completion_tokens: 39, total_tokens: 131}}
        else
          {error: {message: "peg-native test failure", type: "server_error"}}
        end
        {status: Integer(ENV.fetch("TEST_STATUS")), body: JSON.generate(body),
         headers: {"Content-Type" => "application/json"}}
      end
      require_relative "shared/llm_config"
      original_protocol = RubyLLM::Providers::OpenAI.protocols.fetch(:chat_completions)
      begin
        load "07_tracing/run.rb"
      rescue => error
        warn "#{error.class}: #{error.message}"
        exit 1
      ensure
        puts "RESULT:#{JSON.generate(calls: calls, max_retries: RubyLLM.config.max_retries,
          builtin_unchanged: original_protocol.equal?(RubyLLM::Providers::OpenAI.protocols.fetch(:chat_completions)))}"
      end
    RUBY
    env = {"PHRONOMY_MODEL" => "openai/gpt-oss-20b", "PHRONOMY_PROVIDER" => "openai",
           "PHRONOMY_BASE_URL" => "https://example.test/v1", "PHRONOMY_API_KEY" => "test-only",
           "PHRONOMY_CONTEXT_WINDOW" => "131072", "PHRONOMY_MODEL_CAPABILITIES" => nil,
           "PHRONOMY_TRACING_LLM_MODE" => mode, "TEST_RESPONSE" => response, "TEST_STATUS" => status.to_s}
    out, err, process = Open3.capture3(env, RbConfig.ruby, "-e", source,
      chdir: File.expand_path("..", __dir__))
    evidence = JSON.parse(out.lines.find { |line| line.start_with?("RESULT:") }.delete_prefix("RESULT:"))
    [out, err, process, evidence]
  end

  it "adds only repeat_penalty to the real application request and retains tracing" do
    native_out, native_error, native_status, native = run_tracing(mode: nil)
    out, error, status, adapted = run_tracing
    expect(native_status.success?).to be(true), native_error
    expect(status.success?).to be(true), error
    expect(native.fetch("calls").length).to eq(1)
    expect(adapted.fetch("calls").length).to eq(1)
    original = native.fetch("calls").first
    expect(original).to eq("model" => "openai/gpt-oss-20b", "stream" => false, "messages" => [
      {"role" => "system", "content" => "You are a programming expert."},
      {"role" => "user", "content" => "Write a Hello World program in Go. Return code only."}
    ])
    expect(adapted.fetch("calls").first).to eq(original.merge("repeat_penalty" => 1.0))
    expect(adapted).to include("max_retries" => 0, "builtin_unchanged" => true)
    expect(native).to include("max_retries" => 3, "builtin_unchanged" => true)
    [native_out, out].each do |text|
      starts = text.scan(/\[SPAN START\]\s+(\S+)/).flatten
      finishes = text.scan(/\[SPAN END\]\s+(\S+)/).flatten
      expect(starts).not_to be_empty
      expect(finishes.tally).to eq(starts.tally)
      expect(text).to include("--- LLM Response ---", "Hello, World!")
      expect(text).not_to include(" error=")
    end
  end

  [400, 500].each do |code|
    it "propagates HTTP #{code} after one request, including trace failure" do
      out, error, status, evidence = run_tracing(status: code)
      expect(status.success?).to be(false)
      expect(error).to include("peg-native test failure")
      expect(evidence.fetch("calls").length).to eq(1)
      expect(out).to include("[SPAN END]", " error=")
      expect(out).not_to include("--- LLM Response ---")
    end
  end

  it "fails invalid output without requesting another generation" do
    out, error, status, evidence = run_tracing(response: "")
    expect(status.success?).to be(false)
    expect(error).to include("Go code output validation failed")
    expect(evidence.fetch("calls").length).to eq(1)
    expect(out).not_to include("--- LLM Response ---")
  end

  it "rejects an unknown mode before generation" do
    _, error, status, evidence = run_tracing(mode: "typo")
    expect(status.success?).to be(false)
    expect(error).to include("Unknown PHRONOMY_TRACING_LLM_MODE")
    expect(evidence.fetch("calls")).to be_empty
  end

  [{model: "another-model"}, {provider: :anthropic}, {base_url: nil}].each do |invalid|
    it "rejects incompatible configuration #{invalid.inspect} without changing RubyLLM" do
      original = RubyLLM.config.openai_protocol
      expect {
        TracingLLMCompatibility.configure!(**{mode: "lmstudio_gpt_oss", model: "openai/gpt-oss-20b",
          provider: :openai, base_url: "https://example.test/v1"}.merge(invalid))
      }.to raise_error(ArgumentError, /requires/)
      expect(RubyLLM.config.openai_protocol).to eq(original)
      expect(WebMock).not_to have_requested(:any, /chat\/completions/)
    end
  end
end
