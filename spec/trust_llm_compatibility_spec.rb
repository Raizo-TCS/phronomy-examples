# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require_relative "../19_trust_pipeline/llm_compatibility"

RSpec.describe "Example 19 application-owned LLM compatibility" do
  around do |example|
    previous_mode = ENV[TrustLlmCompatibility::ENV_KEY]
    previous_adapter = Phronomy.configuration.llm_adapter
    previous_stdin, previous_args, previous_verbose = $stdin, ARGV.dup, $VERBOSE
    ENV[TrustLlmCompatibility::ENV_KEY] = "tool_then_schema"
    $VERBOSE = nil
    example.run
  ensure
    Phronomy.configuration.llm_adapter = previous_adapter
    ENV[TrustLlmCompatibility::ENV_KEY] = previous_mode
    $stdin = previous_stdin
    ARGV.replace(previous_args)
    $VERBOSE = previous_verbose
  end

  before do
    allow($stdout).to receive(:puts)
    allow($stderr).to receive(:puts)
  end

  def run_case(name)
    Dir.mktmpdir("trust19-compatibility-") do |directory|
      path = File.join(directory, "report.json")
      ARGV.replace(["--case", name, "--report", path, "--snapshot-interval", "0.05"])
      status = nil
      expect { load File.expand_path("../scripts/verify_trust_pipeline.rb", __dir__) }
        .to raise_error(SystemExit) { |error| status = error.status }
      [status, JSON.parse(File.read(path))]
    end
  end

  def draft
    JSON.generate(answer: "Returns are allowed within 30 days.", confidence: 0.95,
      citations: [{source: "refund_policy.md", excerpt: "within 30 days"}])
  end

  %w[yes no cancel].each do |decision|
    it "preserves the real GeneratorVerifier approval-#{decision} acceptance conditions" do
      chat = ExampleChatStub.new do |_body, index|
        case index
        when 0 then ExampleChatStub.tool("approved_policy_lookup", query: "refund")
        when 1 then draft
        else JSON.generate(approved: true, score: 0.95, feedback: "Source verified")
        end
      end
      settings = [RubyLLM.config.request_timeout, RubyLLM.config.max_retries]
      status, report = run_case("approval-#{decision}")
      expect([status, report["status"]]).to eq([0, "passed"]), report["primary_error"].inspect
      expect(report["llm_compatibility_mode"]).to eq("tool_then_schema")
      expect(report["combined_tool_schema_requests"]).to eq(0)
      expect(report["approvals"].length).to eq(1)
      expect(report["tool_executions"]).to eq(decision == "yes" ? 1 : 0)
      expect(report["releases"].last["value"]).to be(true)
      expect(chat.calls.length).to eq(decision == "yes" ? 3 : 1)
      expect(chat.calls.first["tools"].length).to eq(1)
      expect(chat.calls.first).not_to have_key("response_format")
      expect([RubyLLM.config.request_timeout, RubyLLM.config.max_retries]).to eq(settings)
      if decision == "yes"
        expect(report["results"].last.dig("value", "termination_reason")).to eq("accepted")
        expect(chat.calls[1]["tools"]).to be_nil.or be_empty
        expect(chat.calls[1].dig("response_format", "json_schema", "schema", "required"))
          .to eq(%w[answer confidence citations])
        expect(chat.calls[1]["messages"].last["role"]).to eq("tool")
        expect(chat.calls[1]["messages"].last["content"]).to include("30 days")
        expect(chat.calls[2].dig("response_format", "json_schema", "schema", "required"))
          .to eq(%w[approved score feedback])
      end
    end
  end

  it "fails without fabricating approval when a model answers without requesting the Tool" do
    chat = ExampleChatStub.new { draft }
    status, report = run_case("approval-yes")
    expect([status, report["status"], chat.calls.length]).to eq([1, "failed", 1])
    expect(report["approvals"]).to be_empty
    expect(report["tool_executions"]).to eq(0)
    expect(report["primary_error"].first["message"]).to include("was not requested")
    expect(report["releases"].last["value"]).to be(true)
  end

  it "retains strict final-schema rejection and does not replay the approved Tool" do
    chat = ExampleChatStub.new do |_body, index|
      index.zero? ? ExampleChatStub.tool("approved_policy_lookup", query: "refund") :
        JSON.generate(answer: "Policy", confidence: "0.95", citations: [])
    end
    status, report = run_case("approval-yes")
    expect([status, report["status"], chat.calls.length]).to eq([1, "failed", 2])
    result = report["results"].last.fetch("value")
    expect(result["termination_reason"]).to eq("output_failed")
    expect(result.dig("failure", "reason")).to eq("schema_mismatch")
    expect(report["tool_executions"]).to eq(1)
    expect(report["releases"].last["value"]).to be(true)
  end

  %w[tool schema].each do |phase|
    it "preserves #{phase}-phase refusal without starting a replacement generation" do
      chat = ExampleChatStub.new do |_body, index|
        if phase == "schema" && index.zero?
          ExampleChatStub.tool("approved_policy_lookup", query: "refund")
        else
          {role: "assistant", content: draft, refusal: "Declined"}
        end
      end
      status, report = run_case("approval-yes")
      expect([status, report["status"]]).to eq([1, "failed"])
      expect(chat.calls.length).to eq(phase == "schema" ? 2 : 1)
      expect(report["results"].last.dig("value", "failure", "code")).to eq("agent.output_refused")
      expect(report["releases"].last["value"]).to be(true)
    end
  end

  def adapter_request(messages: [], message: "question", tools: nil, model: LLMConfig::MODEL)
    Phronomy::LLMAdapter::Request.new(
      model_config: {model: model, provider: "openai"}, message: message, messages: messages,
      tools: tools || [{name: "approved_policy_lookup", description: "Read policy",
                        parameters_schema: {"type" => "object", "properties" => {"query" => {"type" => "string"}}, "required" => ["query"]}}],
      response_schema: {type: "object", properties: {answer: {type: "string"}}, required: ["answer"]}
    )
  end

  def correlated_messages(id: "lookup-1", result_id: id)
    [Phronomy::LLMAdapter::Message.new(role: :assistant,
       tool_calls: [Phronomy::Tool::CallRequest.new(id: id, name: "approved_policy_lookup", arguments: {query: "refund"})]),
     Phronomy::LLMAdapter::Message.new(role: :tool, content: "30 days", tool_call_id: result_id)]
  end

  let(:backend) { instance_double(Phronomy::LLMAdapter::RubyLLM) }
  let(:adapter) { TrustLlmCompatibility::ApprovedLookupAdapter.new(backend: backend, model: LLMConfig::MODEL) }

  it "uses current request facts for phase selection without changing original schemas or usage" do
    request = adapter_request(message: nil, messages: correlated_messages)
    response = Phronomy::LLMAdapter::Response.new(content: '{"answer":"30 days"}', finish_reason: :stop,
      usage: Phronomy::LLMAdapter::TokenUsage.new(input: 15, output: 5), metadata: {"model_id" => "actual"})
    expect(backend).to receive(:complete) do |wire, cancellation_token:|
      expect(cancellation_token).to be_nil
      expect(wire.tools).to be_empty
      expect(wire.response_schema).to eq(request.response_schema)
      expect(wire.messages).to eq(request.messages)
      response
    end
    value = adapter.complete(request)
    expect(request.tools.length).to eq(1)
    expect(request.response_schema).not_to be_nil
    expect(value.usage).to eq(response.usage)
    expect(value.metadata).to include("model_id" => "actual", "example19_transport_phase" => "schema")
  end

  it "starts a fresh lookup when reused history contains a previous result" do
    request = adapter_request(messages: correlated_messages, message: "new draft question")
    expect(backend).to receive(:complete) do |wire, cancellation_token:|
      expect(wire.response_schema).to be_nil
      expect(wire.tools.length).to eq(1)
      Phronomy::LLMAdapter::Response.new(tool_calls: correlated_messages.first.tool_calls, finish_reason: :tool_calls)
    end
    expect(adapter.complete(request).metadata["example19_transport_phase"]).to eq("tool")
  end

  it "rejects an uncorrelated result before sending a final request" do
    expect(backend).not_to receive(:complete)
    expect { adapter.complete(adapter_request(message: nil, messages: correlated_messages(result_id: "wrong"))) }
      .to raise_error(Phronomy::LLMAdapter::InvalidResultError, /correlated/)
  end

  it "does not silently turn a streaming request into a buffered request" do
    expect(backend).not_to receive(:complete)
    expect(backend).not_to receive(:stream)
    expect { adapter.stream(adapter_request) { |_| } }
      .to raise_error(Phronomy::LLMAdapter::StructuredOutputUnsupportedError, /non-streaming/)
  end

  it "keeps other models and schema-only requests on the existing backend" do
    [adapter_request(model: "other-model"), adapter_request(tools: [])].each do |request|
      response = Phronomy::LLMAdapter::Response.new(content: "unchanged")
      expect(backend).to receive(:complete).with(request, cancellation_token: nil).and_return(response)
      expect(adapter.complete(request)).to equal(response)
    end
  end

  it "does not send anything when cancelled before dispatch" do
    token = Phronomy::Concurrency::CancellationToken.new
    token.cancel!
    expect(backend).not_to receive(:complete)
    expect { adapter.complete(adapter_request, cancellation_token: token) }.to raise_error(Phronomy::CancellationError)
  end

  it "preserves backend failures without another send or fallback" do
    failure = Phronomy::LLMAdapter::TransportError.new("fixture failure")
    expect(backend).to receive(:complete).once.and_raise(failure)
    expect { adapter.complete(adapter_request) }.to raise_error { |error| expect(error).to equal(failure) }
  end

  it "rejects additional Tool calls before approval or execution" do
    calls = correlated_messages.first.tool_calls + correlated_messages(id: "lookup-2").first.tool_calls
    expect(backend).to receive(:complete).once.and_return(
      Phronomy::LLMAdapter::Response.new(tool_calls: calls, finish_reason: :tool_calls))
    expect { adapter.complete(adapter_request) }.to raise_error(Phronomy::LLMAdapter::InvalidResultError, /Expected one/)
  end

  it "rejects unsolicited Tool calls in the final schema phase" do
    expect(backend).to receive(:complete).once.and_return(
      Phronomy::LLMAdapter::Response.new(tool_calls: correlated_messages.first.tool_calls, finish_reason: :tool_calls))
    expect { adapter.complete(adapter_request(message: nil, messages: correlated_messages)) }
      .to raise_error(Phronomy::LLMAdapter::InvalidResultError, /unavailable during/)
  end

  it "preserves incomplete completion facts for Agent rather than retrying" do
    response = Phronomy::LLMAdapter::Response.new(content: "partial", finish_reason: :length,
      metadata: {"raw_finish_reason" => "length"})
    expect(backend).to receive(:complete).once.and_return(response)
    value = adapter.complete(adapter_request)
    expect(value.finish_reason).to eq(:length)
    expect(value.metadata["raw_finish_reason"]).to eq("length")
  end

  it "leaves the default adapter untouched in native mode" do
    ENV.delete(TrustLlmCompatibility::ENV_KEY)
    previous = Phronomy.configuration.llm_adapter
    TrustLlmCompatibility.configure!
    expect(Phronomy.configuration.llm_adapter).to equal(previous)
  end

  it "rejects an unknown mode and does not overwrite an existing custom adapter" do
    ENV[TrustLlmCompatibility::ENV_KEY] = "automatic"
    expect { TrustLlmCompatibility.configure! }.to raise_error(ArgumentError, /must be/)
    ENV[TrustLlmCompatibility::ENV_KEY] = "tool_then_schema"
    Phronomy.configuration.llm_adapter = adapter
    expect { TrustLlmCompatibility.configure! }.to raise_error(ArgumentError, /once at startup/)
    expect(Phronomy.configuration.llm_adapter).to equal(adapter)
  end
end
