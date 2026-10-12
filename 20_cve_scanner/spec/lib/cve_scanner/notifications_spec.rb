# frozen_string_literal: true

require "rails_helper"
require "timeout"

RSpec.describe CveScanner::Notifications do
  let(:sent) { [] }
  let(:server) { ActionCable.server }
  let(:delivery_class) { Phronomy::Integrations::OrderedEventDelivery }

  before do
    allow(server).to receive(:broadcast) do |stream, payload|
      expect(Phronomy::Runtime.in_event_loop_context?).to be(false)
      expect(Rails.application.executor.active?).to be(true)
      sent << [stream, payload]
    end
  end

  after { Phronomy.reset_runtime! }

  def adjust_delivery(**options)
    allow(delivery_class).to receive(:open).and_wrap_original do |original, **kwargs, &block|
      original.call(**kwargs.merge(options), &block)
    end
  end

  def pop(queue)
    Timeout.timeout(3) { queue.pop }
  end

  it "snapshots payloads, drains in order and preserves the block result in a Rails executor" do
    entered, release = Queue.new, Queue.new
    allow(server).to receive(:broadcast).and_wrap_original do |_original, stream, payload|
      entered << true if payload[:type] == "start"
      release.pop if payload[:type] == "start"
      expect(Phronomy::Runtime.in_event_loop_context?).to be(false)
      expect(Rails.application.executor.active?).to be(true)
      sent << [stream, payload]
    end
    result = described_class.open(scan_id: 12) do |delivery|
      delivery.publish(type: "start")
      pop(entered)
      payload = {type: "token", text: +"before", details: [{value: +"original"}]}
      delivery.publish(payload)
      payload[:text].replace("after")
      payload[:details][0][:value].replace("changed")
      delivery.publish(type: "done")
      release << true
      :application_result
    end
    expect(result).to eq(:application_result)
    expect(sent.map(&:first).uniq).to eq(["scan_12"])
    expect(sent.map(&:last)).to eq([
      {type: "start"}, {type: "token", text: "before", details: [{value: "original"}]}, {type: "done"}
    ])
  ensure
    release << true if release
  end

  it "keeps each scope destination separate and closes the old publisher" do
    old = nil
    described_class.open(scan_id: 1) { |delivery| old = delivery; delivery.publish(type: "one") }
    described_class.open(scan_id: 2) { |delivery| delivery.publish(type: "two") }
    expect { old.publish(type: "late") }.to raise_error(delivery_class::ClosedError)
    expect(sent).to eq([["scan_1", {type: "one"}], ["scan_2", {type: "two"}]])
  end

  it "reports an application failure once and re-raises the same exception" do
    primary = IOError.new("application failed")
    expect { described_class.open(scan_id: 3) { raise primary } }
      .to raise_error { |error| expect(error).to equal(primary) }
    expect(sent).to eq([["scan_3", {type: "error", message: "application failed"}]])
  end

  it "returns a transport failure to a successful caller" do
    failure = IOError.new("cable unavailable")
    allow(server).to receive(:broadcast).and_raise(failure)
    expect { described_class.open(scan_id: 3) { |delivery| delivery.publish(type: "done") } }
      .to raise_error { |error| expect(error).to equal(failure) }
  end

  it "preserves the application failure when draining and both diagnostic loggers fail" do
    primary = IOError.new("primary")
    allow(server).to receive(:broadcast).and_raise(IOError, "delivery failed")
    allow(Rails.logger).to receive(:error).and_raise(IOError, "Rails log failed")
    core_logger = double("core logger")
    allow(core_logger).to receive(:error).and_raise(IOError, "core log failed")
    allow(Phronomy.configuration).to receive(:logger).and_return(core_logger)
    expect {
      described_class.open(scan_id: 3) do |delivery|
        delivery.close_and_wait
        raise primary
      end
    }.to raise_error { |error| expect(error).to equal(primary) }
  end

  it "preserves a business error when an accepted error notification fails during drain" do
    primary = ArgumentError.new("business failure")
    allow(server).to receive(:broadcast).and_raise(IOError, "delivery failure")
    expect { described_class.open(scan_id: 3) { raise primary } }
      .to raise_error { |error| expect(error).to equal(primary) }
  end

  it "does not silently drop overflow and drains already accepted payloads" do
    entered, release = Queue.new, Queue.new
    adjust_delivery(capacity: 1, batch_size: 1)
    allow(server).to receive(:broadcast) do |stream, payload|
      if payload[:type] == "first"
        entered << true
        release.pop
      end
      sent << [stream, payload]
    end
    expect {
      described_class.open(scan_id: 4) do |delivery|
        begin
          delivery.publish(type: "first")
          pop(entered)
          delivery.publish(type: "second")
          delivery.publish(type: "overflow")
        ensure
          release << true
        end
      end
    }.to raise_error(delivery_class::OverflowError) { |error| expect(error.code).to eq("delivery.capacity_exceeded") }
    expect(sent.map { |_, payload| payload[:type] }).to eq(%w[first second])
  ensure
    release << true if release
  end

  it "retains an invalid-payload failure even if a producer rescues it" do
    expect {
      described_class.open(scan_id: 4) do |delivery|
        begin
          delivery.publish(type: "error", exception: RuntimeError.new("not plain data"))
        rescue ArgumentError
          # Matches a listener dispatch that logs its own exception and continues.
        end
      end
    }.to raise_error(ArgumentError, /plain data/)
    expect(sent).to be_empty
  end

  it "limits flush waiting without claiming to stop an in-flight delivery" do
    entered, release, finished = Queue.new, Queue.new, Queue.new
    adjust_delivery(flush_timeout: 0.02)
    allow(server).to receive(:broadcast) { entered << true; release.pop; finished << true }
    expect {
      described_class.open(scan_id: 4) do |delivery|
        delivery.publish(type: "done")
        pop(entered)
      end
    }.to raise_error(Phronomy::TimeoutError)
    expect(finished).to be_empty
    release << true
    pop(finished)
  ensure
    release << true if release
  end

  it "lets a real Agent finish while a notification transport is blocked" do
    entered, release = Queue.new, Queue.new
    stub = NotificationChatStub.new { "answer" }
    allow(server).to receive(:broadcast) { entered << true; release.pop }
    described_class.open(scan_id: 5) do |delivery|
      begin
        delivery.publish(type: "slow")
        pop(entered)
        result = CveScanner::ChatAgent.new.invoke_async("question").wait_result(timeout: 3)
        expect(result[:output]).to eq("answer")
        expect(stub.calls.length).to eq(1)
      ensure
        release << true
      end
    end
  ensure
    release << true if release
  end

  it "surfaces overflow from a real Agent listener to the scope caller" do
    entered, release = Queue.new, Queue.new
    adjust_delivery(capacity: 1, batch_size: 1)
    stub = NotificationChatStub.new { '{"decision":"done","proposed_commands":[]}' }
    allow(server).to receive(:broadcast) do |_stream, payload|
      if payload[:type] == "chat_turn_start"
        entered << true
        release.pop
      end
    end
    expect {
      described_class.open(scan_id: 6) do |delivery|
        begin
          task = CveScanner.call_agent_json(CveScanner::CveAnalystAgent, "question", notifications: delivery)
          pop(entered)
          task.wait_result(timeout: 3)
        ensure
          release << true
        end
      end
    }.to raise_error(Phronomy::StreamCallbackError) do |error|
      expect(error.cause).to be_a(delivery_class::OverflowError)
      expect(error.cause.code).to eq("delivery.capacity_exceeded")
    end
    expect(stub.calls.length).to eq(1)
  ensure
    release << true if release
  end
end
