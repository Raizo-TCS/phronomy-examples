# frozen_string_literal: true

require "spec_helper"
require "open3"
require "csv"
require "stringio"

RSpec.describe "Issue analyzer structured output" do
  let(:script) { File.expand_path("../27_issue_analyzer/run.rb", __dir__) }
  let(:issues) { [{number: 123, title: "Feature", state: "OPEN", labels: [], closedAt: nil}] }

  def run_script
    output = StringIO.new
    old = $stdout
    $stdout = output
    load script, true
    output.string
  ensure
    $stdout = old
  end

  before do
    allow(Open3).to receive(:capture3).with(/gh issue list/).and_return([issues.to_json, "", double(success?: true)])
    allow(FileUtils).to receive(:mkdir_p)
    allow(CSV).to receive(:open).and_yield([])
  end

  it "uses validated JSON and preserves known and unknown classification policy" do
    stub = ExampleChatStub.new do
      {"results" => [{"number" => 123, "pairs" => [{"type" => "unknown", "component" => "unknown"}]}]}.to_json
    end
    expect(run_script).to include("(unrecognized)", "Cross-cutting / Framework-wide")
    expect(stub.calls.length).to eq(1)
    expect(stub.calls.first).not_to have_key("response_format")
  end

  ["```json\n{\"results\":[]}\n```", '{"results":"wrong shape"}'].each do |body|
    it "counts a rejected batch without stripping fences or retrying" do
      stub = ExampleChatStub.new { body }
      expect(run_script).to include("PARSE ERROR:", "(parse error)")
      expect(stub.calls.length).to eq(1)
    end
  end
end
