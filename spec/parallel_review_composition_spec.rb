# frozen_string_literal: true

require "spec_helper"
require_relative "../14_code_review/pipeline"

RSpec.describe "Parallel code review result composition" do
  let(:agents) { instance_double(Phronomy::Agent::Scope) }
  let(:application) { Object.new }
  let(:chunks) { [{text: "first"}, {text: "second"}] }
  let(:state) { ReviewState.new(source_code: "whole source", chunks: chunks) }
  let(:responses) { {} }
  let(:started) { [] }
  let(:warnings) { [] }

  def reviewer(name)
    klass = double("#{name} class", name: name, review_knowledge: "#{name} criteria")
    allow(agents).to receive(:create_async).with(klass, knowledge: ["#{name} criteria"]) do
      agent = double("#{name} instance").tap do |agent|
        allow(agent).to receive(:invoke_async) do |text|
          started << [name, text]
          response = responses.fetch([name, text])
          raise response if response.is_a?(Exception)
          response
        end
      end
      Phronomy::TaskResult.completed(agent)
    end
    klass
  end

  def start
    application.send(:start_parallel_reviews, state, agents: agents)
  end

  before do
    allow(application).to receive(:puts)
    allow(application).to receive(:warn) { |message| warnings << message }
  end

  context "controlled Agent completion" do
    let(:first_reviewer) { reviewer("FirstReviewer") }
    let(:second_reviewer) { reviewer("SecondReviewer") }

    before do
      stub_const("REVIEWERS", {first: first_reviewer, second: second_reviewer})
    end

    it "settles an empty reviewer set without starting work" do
      stub_const("REVIEWERS", {})
      expect(start.wait_result(timeout: 2)).to eq({})
      expect(started).to be_empty
    end

    it "keeps every reviewer key when there are no review texts" do
      allow(application).to receive(:review_texts).with(state).and_return([])
      expect(agents).not_to receive(:create_async)
      expect(start.wait_result(timeout: 2)).to eq(first: "", second: "")
    end

    it "handles one already-completed invocation and the whole-source fallback" do
      stub_const("REVIEWERS", {first: first_reviewer})
      chunks.clear
      responses[["FirstReviewer", "whole source"]] = Phronomy::TaskResult.completed({output: "  finding \n"})
      expect(start.wait_result(timeout: 2)).to eq(first: "finding")
      expect(started).to eq([["FirstReviewer", "whole source"]])
    end

    it "starts all invocations before waiting and preserves chunk order under reverse completion" do
      %w[FirstReviewer SecondReviewer].each do |name|
        %w[first second].each { |text| responses[[name, text]] = Phronomy::TaskResult.deferred }
      end
      combined = start
      expect(started).to eq(responses.keys)
      expect(combined).not_to be_done
      responses.to_a.reverse_each do |(name, text), task|
        task.complete({output: " #{name}:#{text} "})
      end
      expect(combined.wait_result(timeout: 2)).to eq(
        first: "FirstReviewer:first\nFirstReviewer:second",
        second: "SecondReviewer:first\nSecondReviewer:second"
      )
    end

    it "does not lose results when many independent completions race" do
      chunks.replace(20.times.map { |index| {text: index.to_s} })
      %w[FirstReviewer SecondReviewer].each do |name|
        20.times { |index| responses[[name, index.to_s]] = Phronomy::TaskResult.deferred }
      end
      combined = start
      workers = responses.to_a.reverse.map do |(name, text), task|
        Thread.new { task.complete({output: "#{name}:#{text}"}) }
      end
      workers.each(&:value)
      expect(combined.wait_result(timeout: 2)).to eq(
        first: 20.times.map { |i| "FirstReviewer:#{i}" }.join("\n"),
        second: 20.times.map { |i| "SecondReviewer:#{i}" }.join("\n")
      )
    ensure
      workers&.each(&:join)
    end

    it "retains successful peers when Agent construction raises" do
      chunks.replace([{text: "first"}])
      error = IOError.new("construction failed")
      allow(agents).to receive(:create_async).with(first_reviewer, knowledge: ["FirstReviewer criteria"]).and_return(Phronomy::TaskResult.failed(error))
      responses[["SecondReviewer", "first"]] = Phronomy::TaskResult.completed({output: "peer finding"})
      expect(start.wait_result(timeout: 2)).to eq(first: "", second: "peer finding")
      expect(warnings).to eq(["[FirstReviewer] chunk 1/1: IOError: construction failed"])
    end

    it "retains successful chunks when invoke_async raises at startup without retrying" do
      stub_const("REVIEWERS", {first: first_reviewer})
      responses[["FirstReviewer", "first"]] = IOError.new("admission failed")
      responses[["FirstReviewer", "second"]] = Phronomy::TaskResult.completed({output: "usable"})
      expect(start.wait_result(timeout: 2)).to eq(first: "usable")
      expect(started).to eq([["FirstReviewer", "first"], ["FirstReviewer", "second"]])
      expect(warnings).to eq(["[FirstReviewer] chunk 1/2: IOError: admission failed"])
    end

    it "waits for all results before warning about asynchronous failures in input order" do
      stub_const("REVIEWERS", {first: first_reviewer})
      one = responses[["FirstReviewer", "first"]] = Phronomy::TaskResult.deferred
      two = responses[["FirstReviewer", "second"]] = Phronomy::TaskResult.deferred
      combined = start
      two.fail(IOError.new("second failed"))
      expect(combined).not_to be_done
      expect(warnings).to be_empty
      one.fail(ArgumentError.new("first failed"))
      expect(combined.wait_result(timeout: 2)).to eq(first: "")
      expect(warnings).to eq([
        "[FirstReviewer] chunk 1/2: ArgumentError: first failed",
        "[FirstReviewer] chunk 2/2: IOError: second failed"
      ])
    end

    it "excludes a cancelled child while letting its peer finish" do
      stub_const("REVIEWERS", {first: first_reviewer})
      one = responses[["FirstReviewer", "first"]] = Phronomy::TaskResult.deferred
      two = responses[["FirstReviewer", "second"]] = Phronomy::TaskResult.deferred
      combined = start
      error = Phronomy::CancellationError.new("cancel requested")
      one.cancel!(error)
      expect(two.status).to eq(:pending)
      expect(combined).not_to be_done
      two.complete({output: "peer finding"})
      expect(combined.wait_result(timeout: 2)).to eq(first: "peer finding")
      expect(one.status).to eq(:cancelled)
      expect { one.wait_result }.to raise_error { |caught| expect(caught).to equal(error) }
      expect(warnings).to eq(["[FirstReviewer] chunk 1/2: Phronomy::CancellationError: cancel requested"])
    end

    it "collects delayed output transformation failure instead of leaving completion pending" do
      stub_const("REVIEWERS", {first: first_reviewer})
      one = responses[["FirstReviewer", "first"]] = Phronomy::TaskResult.deferred
      responses[["FirstReviewer", "second"]] = Phronomy::TaskResult.completed({output: "usable"})
      combined = start
      invalid_output = Object.new
      def invalid_output.to_s = raise(TypeError, "unusable output")
      one.complete({output: invalid_output})
      expect(combined.wait_result(timeout: 2)).to eq(first: "usable")
      expect(one.status).to eq(:completed)
      expect(warnings).to eq(["[FirstReviewer] chunk 1/2: TypeError: unusable output"])
    end

    it "preserves empty output handling and removes blank chunks" do
      stub_const("REVIEWERS", {first: first_reviewer})
      chunks.replace((1..4).map { |index| {text: index.to_s} })
      [{}, {output: nil}, {output: " \n "}, {output: " usable "}].each_with_index do |value, index|
        responses[["FirstReviewer", (index + 1).to_s]] = Phronomy::TaskResult.completed(value)
      end
      expect(start.wait_result(timeout: 2)).to eq(first: "usable")
      expect(warnings).to be_empty
    end

    it "returns all reviewer keys with empty findings when every child fails" do
      %w[FirstReviewer SecondReviewer].each do |name|
        %w[first second].each do |text|
          responses[[name, text]] = Phronomy::TaskResult.failed(IOError.new("unavailable"))
        end
      end
      expect(start.wait_result(timeout: 2)).to eq(first: "", second: "")
      expect(warnings.length).to eq(4)
      expect(started.length).to eq(4)
    end

    it "surfaces an application aggregation error through the returned result" do
      stub_const("REVIEWERS", {first: first_reviewer})
      chunks.replace([{text: "first"}])
      responses[["FirstReviewer", "first"]] = Phronomy::TaskResult.failed(IOError.new("child failed"))
      reporting_error = IOError.new("stderr unavailable")
      allow(application).to receive(:warn).and_raise(reporting_error)
      expect { start.wait_result(timeout: 2) }.to raise_error { |error| expect(error).to equal(reporting_error) }
    end
  end

  it "returns real Agent results through Workflow completion and pauses for the review priority" do
    stub = ExampleChatStub.new { " finding " }
    Phronomy::Agent.open_scope do |scope|
      workflow = application.send(:build_pipeline, agents: scope)
      result = workflow.invoke({file_path: "sample.rb", source_code: "puts :hello"},
        config: {workflow_instance_id: "dx05-review-composition"})
      expect(result).to be_halted
      expect(result.phase).to eq(:awaiting_priority)
      expect(result.reviews).to eq(REVIEWERS.to_h { |key, _| [key, "finding"] })
    end
    expect(stub.calls.length).to eq(4)
  end
end
