# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"

RSpec.describe "RubyLLM model registry configuration" do
  def config_in_process(**environment)
    source = <<~'SOURCE'
      require "webmock"
      include WebMock::API
      WebMock.enable!
      WebMock.disable_net_connect!
      stub_request(:get, /api\/v0\/models/).to_return(status: 404)
      require_relative "shared/llm_config"
      model = RubyLLM.models.find(LLMConfig::MODEL, provider: LLMConfig::PROVIDER)
      input_limit = begin
        LLMConfig.input_token_limit!
      rescue ArgumentError
        nil
      end
      budget = Phronomy::LLMAdapter::RubyLLM.new.input_budget(model: LLMConfig::MODEL, provider: LLMConfig::PROVIDER)
      selected = model.provider
      expected_key = ENV["PHRONOMY_API_KEY"] || ENV["#{selected.to_s.upcase}_API_KEY"]
      puts JSON.generate(provider: model.provider, context_window: model.context_window,
        protocol: RubyLLM.config.openai_protocol, capabilities: model.capabilities,
        input_token_limit: input_limit, adapter_input_budget: budget&.effective_input_limit,
        selected_base: RubyLLM.config.public_send("#{selected}_api_base"),
        selected_key_matches: RubyLLM.config.public_send("#{selected}_api_key") == expected_key,
        openai_key_present: !RubyLLM.config.openai_api_key.nil?,
        openai_base: RubyLLM.config.openai_api_base,
        request_timeout: RubyLLM.config.request_timeout, max_retries: RubyLLM.config.max_retries)
    SOURCE
    base = {"PHRONOMY_MODEL" => "gpt-4o-mini", "PHRONOMY_PROVIDER" => "openai",
            "PHRONOMY_CONTEXT_WINDOW" => nil, "PHRONOMY_BASE_URL" => nil,
            "PHRONOMY_MODEL_CAPABILITIES" => nil, "PHRONOMY_API_KEY" => "test-only",
            "OPENAI_API_KEY" => nil, "AZURE_API_KEY" => nil, "ANTHROPIC_API_KEY" => nil,
            "GEMINI_API_KEY" => nil, "OLLAMA_API_KEY" => nil}
    Open3.capture3(base.merge(environment.transform_keys(&:to_s)), RbConfig.ruby, "-e", source,
      chdir: File.expand_path("..", __dir__))
  end

  it "registers the declared input limit without subtracting an output reserve" do
    model = RubyLLM.models.find(LLMConfig::MODEL, provider: LLMConfig::PROVIDER)
    expect(model.context_window).to eq(8192)
    expect(LLMConfig).not_to respond_to(:apply_phronomy_defaults!)
  end

  it "registers an unknown custom model through the public registry loader" do
    output, error, status = config_in_process(PHRONOMY_MODEL: "local-custom", PHRONOMY_CONTEXT_WINDOW: "4096")
    expect(status.success?).to be(true), error
    expect(JSON.parse(output)).to include("context_window" => 4096, "provider" => "openai")
  end

  it "does not borrow cloud limits or invent a fallback when local metadata is unknown" do
    output, error, status = config_in_process(PHRONOMY_BASE_URL: "https://example.test/v1")
    expect(status.success?).to be(true), error
    expect(JSON.parse(output)).to include("context_window" => nil, "protocol" => "chat_completions")
  end

  it "rejects invalid explicit metadata" do
    _, error, status = config_in_process(PHRONOMY_CONTEXT_WINDOW: "0")
    expect(status.success?).to be(false)
    expect(error).to include("PHRONOMY_CONTEXT_WINDOW must be positive")
  end

  it "keeps the existing local capabilities when no declaration is supplied" do
    output, error, status = config_in_process(PHRONOMY_MODEL: "local-custom", PHRONOMY_BASE_URL: "https://example.test/v1")
    expect(status.success?).to be(true), error
    expect(JSON.parse(output).fetch("capabilities")).to eq(%w[function_calling streaming])
  end

  it "registers explicit capabilities without requiring a URL or context limit" do
    output, error, status = config_in_process(PHRONOMY_MODEL: "local-custom",
      PHRONOMY_MODEL_CAPABILITIES: "function_calling, streaming, structured_output, streaming")
    expect(status.success?).to be(true), error
    expect(JSON.parse(output)).to include("context_window" => nil,
      "capabilities" => %w[function_calling streaming structured_output])
  end

  it "preserves the declared lack of Tool capability" do
    output, error, status = config_in_process(PHRONOMY_MODEL: "local-custom", PHRONOMY_CONTEXT_WINDOW: "4096",
      PHRONOMY_MODEL_CAPABILITIES: "structured_output")
    expect(status.success?).to be(true), error
    expect(JSON.parse(output).fetch("capabilities")).to eq(["structured_output"])
  end

  [nil, "openai"].each do |provider|
    it "preserves cloud input metadata when only capabilities change with provider=#{provider.inspect}" do
      output, error, status = config_in_process(PHRONOMY_PROVIDER: provider,
        PHRONOMY_MODEL_CAPABILITIES: "function_calling,structured_output")
      expect(status.success?).to be(true), error
      expect(JSON.parse(output)).to include("context_window" => 128_000,
        "input_token_limit" => 128_000, "adapter_input_budget" => 128_000,
        "capabilities" => %w[function_calling structured_output])
    end
  end

  it "uses an explicit input limit when cloud capabilities also change" do
    output, error, status = config_in_process(PHRONOMY_CONTEXT_WINDOW: "4096",
      PHRONOMY_MODEL_CAPABILITIES: "structured_output")
    expect(status.success?).to be(true), error
    expect(JSON.parse(output)).to include("context_window" => 4096,
      "input_token_limit" => 4096, "adapter_input_budget" => 4096)
  end

  it "keeps a known cloud model's local input limit unknown when only capabilities are supplied" do
    output, error, status = config_in_process(PHRONOMY_BASE_URL: "https://example.test/v1",
      PHRONOMY_MODEL_CAPABILITIES: "structured_output")
    expect(status.success?).to be(true), error
    expect(JSON.parse(output)).to include("context_window" => nil,
      "input_token_limit" => nil, "adapter_input_budget" => nil)
  end

  ["", " , , "].each do |declaration|
    it "rejects an empty capability declaration #{declaration.inspect}" do
      _, error, status = config_in_process(PHRONOMY_MODEL_CAPABILITIES: declaration)
      expect(status.success?).to be(false)
      expect(error).to include("PHRONOMY_MODEL_CAPABILITIES must contain a capability")
    end
  end

  %w[azure anthropic gemini ollama].each do |provider|
    it "applies endpoint and credentials to #{provider} without configuring OpenAI" do
      output, error, status = config_in_process(PHRONOMY_PROVIDER: provider,
        PHRONOMY_MODEL: "custom-deployment", PHRONOMY_BASE_URL: "https://selected.example.test/v1",
        PHRONOMY_CONTEXT_WINDOW: "4096")
      expect(status.success?).to be(true), error
      expect(JSON.parse(output)).to include("provider" => provider,
        "selected_base" => "https://selected.example.test/v1", "selected_key_matches" => true,
        "openai_key_present" => false, "openai_base" => nil, "protocol" => nil,
        "context_window" => 4096, "request_timeout" => 300, "max_retries" => 3)
    end
  end

  it "uses the selected provider's environment key when no generic key is supplied" do
    output, error, status = config_in_process(PHRONOMY_PROVIDER: "azure",
      PHRONOMY_MODEL: "custom-deployment", PHRONOMY_BASE_URL: "https://selected.example.test/openai/v1",
      PHRONOMY_API_KEY: nil, AZURE_API_KEY: "azure-test-only", OPENAI_API_KEY: "unrelated-test-only")
    expect(status.success?).to be(true), error
    expect(JSON.parse(output)).to include("selected_key_matches" => true, "openai_key_present" => false)
  end

  it "uses the registered model's provider when the provider is omitted" do
    model = RubyLLM.models.all.find { |entry| entry.provider == "anthropic" }
    output, error, status = config_in_process(PHRONOMY_PROVIDER: nil, PHRONOMY_MODEL: model.id,
      PHRONOMY_API_KEY: nil, ANTHROPIC_API_KEY: "anthropic-test-only", OPENAI_API_KEY: "unrelated-test-only")
    expect(status.success?).to be(true), error
    expect(JSON.parse(output)).to include("provider" => "anthropic",
      "selected_key_matches" => true, "openai_key_present" => false)
  end

  it "does not substitute OpenAI credentials for missing Azure credentials" do
    output, error, status = config_in_process(PHRONOMY_PROVIDER: "azure",
      PHRONOMY_MODEL: "custom-deployment", PHRONOMY_BASE_URL: "https://selected.example.test/openai/v1",
      PHRONOMY_API_KEY: nil, OPENAI_API_KEY: "unrelated-test-only")
    expect(status.success?).to be(true), error
    expect(JSON.parse(output)).to include("selected_key_matches" => true, "openai_key_present" => false)
  end

  it "rejects generic credentials for providers without a matching SDK setting" do
    _output, error, status = config_in_process(PHRONOMY_PROVIDER: "unknown-provider")
    expect(status.success?).to be(false)
    expect(error).to include("PHRONOMY_API_KEY cannot configure provider unknown-provider")
  end
end
