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
      puts JSON.generate(provider: model.provider, context_window: model.context_window,
        protocol: RubyLLM.config.openai_protocol)
    SOURCE
    base = {"PHRONOMY_MODEL" => "gpt-4o-mini", "PHRONOMY_PROVIDER" => "openai",
            "PHRONOMY_CONTEXT_WINDOW" => nil, "PHRONOMY_BASE_URL" => nil}
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
end
