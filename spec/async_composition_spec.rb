# frozen_string_literal: true

require "spec_helper"
require_relative "../32_async_composition/majority"
require_relative "../32_async_composition/agents"

RSpec.describe "Async majority application" do
  it "gets a majority from independent Agent results" do
    stub = ExampleChatStub.new { |_request, index| %w[YES NO YES].fetch(index) }
    agents = Array.new(3) { MajorityVoter.new }
    report = AsyncMajority.run_async(agents, question: "Use tests?").wait_result
    expect(report.fetch(:decision)).to eq("YES")
    expect(report.fetch(:counts)).to eq("YES" => 2, "NO" => 1, "ABSTAIN" => 0)
    expect(stub.calls.length).to eq(3)
  end

  it "includes the asynchronous evaluation in each JOB's final vote" do
    stub = ExampleChatStub.new do |request, _index|
      input = request.fetch("messages").reverse.find { |message| message["role"] == "user" }.fetch("content")
      input.include?("Proposed answer:") ? "NO" : "YES"
    end
    pairs = Array.new(3) { {voter: MajorityVoter.new, evaluator: MajorityEvaluator.new} }
    report = AsyncMajority.run_evaluated_async(pairs, question: "Use tests?").wait_result
    expect(report.fetch(:decision)).to eq("NO")
    expect(report.fetch(:outcomes).map(&:value)).to eq(%w[NO NO NO])
    expect(stub.calls.length).to eq(6)
  end

  it "preserves invalid votes as failed outcomes and requires a majority of all voters" do
    ExampleChatStub.new { |_request, index| ["YES", "unsure", "NO"].fetch(index) }
    report = AsyncMajority.run_async(Array.new(3) { MajorityVoter.new }, question: "Use tests?").wait_result
    expect(report.fetch(:decision)).to eq("INCONCLUSIVE")
    expect(report.fetch(:counts).fetch("ABSTAIN")).to eq(1)
    failed = report.fetch(:outcomes).find { |outcome| outcome.status == :failed }
    expect(failed.error).to be_a(ArgumentError)
  end

  it "has no majority for empty input and keeps timeout records available" do
    expect(AsyncMajority.run_async([], question: "Use tests?").wait_result.fetch(:decision)).to eq("INCONCLUSIVE")
    result = AsyncMajority.run_async([MajorityVoter.new], question: "Use tests?", timeout: 0)
    expect { result.wait_result }.to raise_error(Phronomy::ExecutionTimeoutError) { |error|
      expect(error.outcomes.first.status).to eq(:unfinished)
    }
  end
end
