# frozen_string_literal: true

require "spec_helper"
require "ostruct"
require_relative "../14_code_review/pipeline"

RSpec.describe "Application result transformation and Workflow event mapping" do
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
      .and_return(Phronomy::Task.completed({output: "candidate", metadata: "kept by source Task"}))
    expect(CODE_OUTPUT_GUARDRAIL).to receive(:call).with("candidate")
      .and_raise(Phronomy::FilterBlockError, "warning only")
    expect(application.send(:start_improvement, snapshot).wait_result).to eq("candidate")
  end

  it "preserves optional output extraction instead of introducing a fetch requirement" do
    agent = double("ImproverAgent", invoke_async: Phronomy::Task.completed({}))
    allow(application).to receive(:load_or_create_improver).and_return(agent)
    allow(CODE_OUTPUT_GUARDRAIL).to receive(:call)
    expect(application.send(:start_improvement, snapshot).wait_result).to eq("")
  end

  it "turns a startup exception into a failed Task with the original error" do
    error = RuntimeError.new("Agent could not be loaded")
    allow(application).to receive(:load_or_create_improver).and_raise(error)
    task = application.send(:start_improvement, snapshot)
    expect { task.wait_result }.to raise_error { |caught| expect(caught).to equal(error) }
  end

  it "lets the application choose same or different events for already finished Tasks" do
    workflow = double("Workflow")
    expect(workflow).to receive(:signal).with(workflow_instance_id: "one", event: :reviewed, payload: {security: "a"}).ordered
    expect(workflow).to receive(:signal).with(workflow_instance_id: "one", event: :reviewed, payload: {performance: "b"}).ordered
    error = RuntimeError.new("evaluation failed")
    expect(workflow).to receive(:signal).with(workflow_instance_id: "one", event: :evaluated, payload: {error: error}).ordered
    [[:reviewed, :security, Phronomy::Task.completed("a")],
      [:reviewed, :performance, Phronomy::Task.completed("b")],
      [:evaluated, :scores, Phronomy::Task.failed(error)]].each do |event, key, task|
      application.send(:signal_completion, workflow,
        workflow_instance_id: "one", event: event, key: key, operation: task)
    end
  end
end
