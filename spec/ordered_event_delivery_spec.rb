# frozen_string_literal: true

require "spec_helper"
require "timeout"
require_relative "../18_rails_agent_job/app/services/ordered_event_delivery"

RSpec.describe OrderedEventDelivery do
  it "copies queued data and combines only adjacent tokens without moving done" do
    started = Queue.new
    release = Queue.new
    sent = []
    delivery = described_class.new do |payload|
      if payload[:type] == "tool_result"
        started << true
        release.pop
      end
      sent << payload
    end
    delivery.publish(type: "tool_result")
    Timeout.timeout(2) { started.pop }
    token = {type: "token", content: +"A"}
    delivery.publish(token)
    token[:content].replace("changed")
    delivery.publish(type: "token", content: "B")
    delivery.publish(type: "done", output: "AB")
    release << true
    delivery.close_and_wait(timeout: 2)

    expect(sent).to eq([
      {type: "tool_result"}, {type: "token", content: "AB"}, {type: "done", output: "AB"}
    ])
    expect { delivery.publish(type: "done") }.to raise_error(described_class::ClosedError)
  ensure
    release << true if release
  end

  it "keeps differently identified token streams separate" do
    # Hold the first delivery so both tokens are in the same next batch.
    started = Queue.new
    release = Queue.new
    sent = []
    delivery = described_class.new do |payload|
      if payload[:type] == "start"
        started << true
        release.pop
      end
      sent << payload
    end
    delivery.publish(type: "start")
    Timeout.timeout(2) { started.pop }
    delivery.publish(type: "token", role: "a", content: "A")
    delivery.publish(type: "token", role: "b", content: "B")
    release << true
    delivery.close_and_wait(timeout: 2)
    expect(sent.map { |payload| payload[:content] }).to eq([nil, "A", "B"])
  ensure
    release << true if release
  end

  it "rejects overflow without waiting or silently replacing queued events" do
    started = Queue.new
    release = Queue.new
    sent = []
    delivery = described_class.new(capacity: 1) do |payload|
      if payload[:id] == 1
        started << true
        release.pop
      end
      sent << payload[:id]
    end
    delivery.publish(id: 1)
    Timeout.timeout(2) { started.pop }
    delivery.publish(id: 2)
    expect { Timeout.timeout(2) { delivery.publish(id: 3) } }
      .to raise_error(described_class::OverflowError)
    release << true
    expect { delivery.close_and_wait(timeout: 2) }.to raise_error(described_class::OverflowError)
    expect(sent).to eq([1, 2])
  ensure
    release << true if release
  end

  it "retains invalid payload failures for flush even when a listener rescues" do
    delivery = described_class.new { |_payload| nil }
    begin
      delivery.publish(value: Object.new)
    rescue ArgumentError
      # Agent event listeners can log the callback exception and continue.
    end
    expect { delivery.close_and_wait(timeout: 2) }.to raise_error(ArgumentError, /plain data/)
  end

  it "propagates a delivery failure and stops accepting work" do
    failure = RuntimeError.new("broadcast failed")
    delivery = described_class.new { raise failure }
    begin
      delivery.publish(type: "done")
    rescue RuntimeError => error
      expect(error).to equal(failure)
    end
    expect { delivery.close_and_wait(timeout: 2) }.to raise_error { |error| expect(error).to equal(failure) }
    expect { delivery.publish(type: "done") }.to raise_error { |error| expect(error).to equal(failure) }
  end

  it "reports worker admission failure without leaving flush pending" do
    failure = Phronomy::BackpressureError.new("pool full")
    allow(Phronomy::Blocking).to receive(:call_async).and_return(Phronomy::Task.failed(failure))
    delivery = described_class.new { raise "must not deliver" }
    expect { delivery.publish(type: "done") }.to raise_error { |error| expect(error).to equal(failure) }
    expect { delivery.close_and_wait(timeout: 2) }.to raise_error { |error| expect(error).to equal(failure) }
  end

  it "times out only the flush wait and lets in-flight delivery finish" do
    started = Queue.new
    release = Queue.new
    delivered = Queue.new
    delivery = described_class.new do |_payload|
      started << true
      release.pop
      delivered << true
    end
    delivery.publish(type: "done")
    Timeout.timeout(2) { started.pop }
    expect { delivery.close_and_wait(timeout: 0.01) }.to raise_error(Phronomy::TimeoutError)
    expect(delivered).to be_empty
    release << true
    delivery.close_and_wait(timeout: 2)
    expect(delivered.pop).to be(true)
  ensure
    release << true if release
  end

  it "serializes concurrent publishers without losing accepted events" do
    sent = []
    active = 0
    peak = 0
    delivery = described_class.new(capacity: 256) do |payload|
      active += 1
      peak = [peak, active].max
      Thread.pass
      sent << payload
      active -= 1
    end
    publishers = 4.times.map do |producer|
      Thread.new do
        20.times { |index| delivery.publish(producer: producer, index: index) }
      end
    end
    publishers.each(&:value)
    delivery.close_and_wait(timeout: 2)
    expect(peak).to eq(1)
    expect(sent.length).to eq(80)
    4.times do |producer|
      expect(sent.select { |payload| payload[:producer] == producer }.map { |payload| payload[:index] })
        .to eq((0...20).to_a)
    end
  end

  it "does not let a lifecycle callback wait for a delivery flush" do
    delivery = described_class.new { |_payload| nil }
    allow(Phronomy::Runtime).to receive(:in_event_loop_context?).and_return(true)
    expect { delivery.close_and_wait }.to raise_error(Phronomy::EventLoopReentrancyError)
  end
end
