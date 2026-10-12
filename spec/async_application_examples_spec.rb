# frozen_string_literal: true

require "spec_helper"
require "ostruct"
require_relative "../14_code_review/pipeline"

RSpec.describe "Application result transformation and Workflow task states" do
  let(:application) { Object.new }
  let(:snapshot) { OpenStruct.new(priority: nil) }

  before do
    allow(application).to receive(:build_improvement_prompt).and_return("prompt")
    allow(application).to receive(:puts)
  end

  it "keeps response extraction and the warn-only output policy in the map block" do
    agent = double("ImproverAgent")
    allow(application).to receive(:load_or_create_improver).and_return(agent)
    expect(agent).to receive(:invoke_async).with({message: "prompt", priority: "security"})
      .and_return(Phronomy::TaskResult.completed({output: "candidate", metadata: "kept by source TaskResult"}))
    expect(CODE_OUTPUT_GUARDRAIL).to receive(:call).with("candidate")
      .and_raise(Phronomy::FilterBlockError, "warning only")
    expect(application.send(:start_improvement, snapshot).wait_result).to eq("candidate")
  end

  it "preserves optional output extraction instead of introducing a fetch requirement" do
    agent = double("ImproverAgent", invoke_async: Phronomy::TaskResult.completed({}))
    allow(application).to receive(:load_or_create_improver).and_return(agent)
    allow(CODE_OUTPUT_GUARDRAIL).to receive(:call)
    expect(application.send(:start_improvement, snapshot).wait_result).to eq("")
  end

  it "turns a startup exception into a failed TaskResult with the original error" do
    error = RuntimeError.new("Agent could not be loaded")
    allow(application).to receive(:load_or_create_improver).and_raise(error)
    task = application.send(:start_improvement, snapshot)
    expect { task.wait_result }.to raise_error { |caught| expect(caught).to equal(error) }
  end

  it "applies all three task states across the priority halt and resume" do
    stub = ExampleChatStub.new do |_request, index|
      case index
      when 0..3 then "review finding"
      when 4 then "```ruby\nputs :improved\n```"
      else "0.8"
      end
    end
    workflow = application.send(:build_pipeline)
    halted = workflow.invoke({file_path: "sample.rb", source_code: "puts :original"})
    expect(halted.phase).to eq(:awaiting_priority)
    expect(halted.reviews.values).to all(eq("review finding"))
    finished = workflow.send_event(state: halted, event: :proceed, input: {priority: "security"})
    expect(finished.improved_code).to include("puts :improved")
    expect(finished.quality_scores).to eq(review_quality: 8.0, improvement_quality: 8.0)
    expect(stub.calls.length).to eq(7)
  end
end
