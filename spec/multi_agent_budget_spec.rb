# frozen_string_literal: true

require "spec_helper"
require_relative "../05_multi_agent/agents"

RSpec.describe "Example 05 capacity allocation" do
  def model_capacity(window, output_limit = nil)
    allow(RubyLLM.models).to receive(:find).and_wrap_original do |original, *args, **kwargs|
      model = original.call(*args, **kwargs)
      if model.id == LLMConfig::MODEL && model.provider.to_s == LLMConfig::PROVIDER.to_s
        RubyLLM::Model.new(model.to_h.merge(context_window: window, max_output_tokens: output_limit))
      else
        model
      end
    end
  end

  def observe_policy
    policy = Class.new(Example05InputPolicy) do
      attr_reader :inputs, :plans
      def initialize
        @inputs = []
        @plans = []
      end
      def call(input)
        @inputs << input
        super.tap { |selected| @plans << selected }
      end
    end.new
    allow(ResearcherAgent).to receive(:context_policy).and_return(policy)
    policy
  end

  def ask_researcher(text, **options)
    Phronomy::Agent.open_scope { |scope| scope.create(ResearcherAgent, **options).invoke_async(text) }
  end

  [
    [8192, nil, 2048, 512, 5632],
    [131072, nil, 32768, 8192, 90112],
    [131072, 8192, 8192, 8192, 114688]
  ].each do |window, provider_limit, output, margin, input|
    it "sends the allocated output cap and reserves input with context #{window}, output limit #{provider_limit.inspect}" do
      model_capacity(window, provider_limit)
      policy = observe_policy
      stub = ExampleChatStub.new { "Five concise findings from the supplied topic." }
      ask_researcher("Research Ruby")
      expect(stub.calls.length).to eq(1)
      expect(stub.calls.first.fetch("max_completion_tokens")).to eq(output)
      expect(policy.plans.first.metadata).to include(
        "example05_context_window" => window, "example05_output_tokens" => output,
        "example05_safety_margin" => margin, "example05_input_limit" => input)
      expect(policy.plans.first.metadata.fetch("example05_selected_tokens")).to be <= input
    end
  end

  it "re-reads metadata for a later call rather than caching an output constant" do
    windows = [8192, 16384]
    adapter = Phronomy.configuration.llm_adapter
    allow(adapter).to receive(:input_budget) do
      double(max_input_tokens: windows.shift)
    end
    expect(Example05Budget.patch(nil).model_config_patch.fetch(:max_output_tokens)).to eq(2048)
    expect(Example05Budget.patch(nil).model_config_patch.fetch(:max_output_tokens)).to eq(4096)
  end

  it "fits optional history within the input allocation while retaining the logical transcript" do
    model_capacity(8192)
    policy = observe_policy
    stub = ExampleChatStub.new { "A concise answer using the current question." }
    history = 10.times.flat_map do |i|
      [{role: "user", content: "History marker #{i}: " + "planning note " * 140},
       {role: "assistant", content: "Recorded history #{i}: " + "archived note " * 140}]
    end
    result = ask_researcher("Answer the current question.", context: history)
    actual = stub.calls.first.fetch("messages").map { |message| message["content"].to_s }.join("\n")
    expect(actual).not_to include("History marker 0:")
    expect(actual).to include("History marker 9:", "Answer the current question.")
    expect(result.fetch(:messages).map(&:content).join("\n")).to include("History marker 0:")
    expect(policy.plans.first.metadata.fetch("example05_selected_tokens")).to be <= 5632
  end

  it "rejects mandatory input that cannot fit before sending an HTTP request" do
    model_capacity(8192)
    expect { ask_researcher("Mandatory current input. " * 2000) }
      .to raise_error(Phronomy::Context::BudgetExceededError)
    expect(WebMock).not_to have_requested(:post, "https://example.test/v1/chat/completions")
  end

  it "fails before generation when registered context is unknown" do
    model_capacity(nil)
    expect { ask_researcher("Research Ruby") }
      .to raise_error(Phronomy::ConfigurationError, /known model context capacity/)
    expect(WebMock).not_to have_requested(:post, "https://example.test/v1/chat/completions")
  end

  it "does not mask errors raised by the configured Adapter" do
    failure = Phronomy::ConfigurationError.new("Adapter metadata failure")
    allow(Phronomy.configuration.llm_adapter).to receive(:input_budget).and_raise(failure)
    expect { Example05Budget.current }.to raise_error { |error| expect(error).to equal(failure) }
  end

  it "rejects invalid capacities instead of inventing fallback numbers" do
    [nil, 0, -1, "8192", 8192.0, 1].each do |window|
      expect { Example05Budget.allocate(window: window) }.to raise_error(Phronomy::ConfigurationError)
    end
    [0, -1, "2048", 2048.0].each do |output|
      expect { Example05Budget.allocate(window: 8192, output_limit: output) }
        .to raise_error(Phronomy::ConfigurationError)
    end
  end

  it "refuses an output cap incompatible with the capacity seen by ContextPolicy" do
    policy = observe_policy
    model_capacity(8192)
    ExampleChatStub.new { "A concise answer." }
    ask_researcher("Research Ruby")
    original = policy.inputs.first
    changed = original.with(model_config: original.model_config.merge("max_output_tokens" => 4096))
    expect { Example05InputPolicy.new.call(changed) }
      .to raise_error(Phronomy::ConfigurationError, /exceeds Example 05's share/)
  end

  it "includes Tool framing in the canonical input check" do
    model_capacity(8192)
    policy = observe_policy
    ExampleChatStub.new { "A concise answer." }
    ask_researcher("Research Ruby")
    original = policy.inputs.first
    tool = Phronomy::Context::ContextPolicyInput::ToolItem.new(
      id: "large-schema", definition: {"name" => "fixture", "description" => "X" * 30_000},
      estimated_tokens: 1, required: true)
    expect { Example05InputPolicy.new.call(original.with(tools: [tool])) }
      .to raise_error(Phronomy::Context::BudgetExceededError, /Tool framing/)
  end
end
