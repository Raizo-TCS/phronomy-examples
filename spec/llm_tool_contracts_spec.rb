# frozen_string_literal: true

require "spec_helper"
require_relative "../33_llm_tool_contracts/run"

RSpec.describe ContractExample do
  around do |example|
    old = Phronomy.configuration.llm_adapter
    example.run
  ensure
    Phronomy.configuration.llm_adapter = old
  end

  it "runs an independent backend through Agent and Tool continuation" do
    expect(RubyLLM).not_to receive(:chat)
    expect(described_class.run).to eq("Result: 6")
  end

  it "enforces the explicit advertised schema before execute" do
    tool = described_class::DoubleValue.new
    expect(tool).not_to receive(:execute)
    [{"n" => "3"}, {"n" => 2.5}, {}, {"n" => 3, "extra" => true}].each do |arguments|
      expect { tool.call(arguments) }.to raise_error(Phronomy::ToolError)
    end
  end
end
