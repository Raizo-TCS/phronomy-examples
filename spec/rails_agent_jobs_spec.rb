# frozen_string_literal: true

require "spec_helper"
require "ostruct"
require "phronomy/integrations/ordered_event_delivery"
require_relative "../18_rails_agent_job/app/services/token_event_batch"

# Unit tests of the complete application Jobs. Rails/Action Cable are test
# doubles here; real Phronomy Tasks and OffloadPool run the delivery adapter.
RSpec.describe "Basic and streaming Rails Agent jobs" do
  before do
    base = Class.new do
      def self.queue_as(_queue)
      end
    end
    stub_const("ApplicationJob", base)
    stub_const("DemoAgent", Class.new)
    @agents = instance_double(Phronomy::Agent::Scope)
    allow(Phronomy::Agent).to receive(:open_scope).and_yield(@agents)
    stub_const("AgentResultJob", Class.new(base))
    stub_const("AgentStreamingJob", Class.new(base))
    stub_const("Rails", Module.new)
    stub_const("ActionCable", Module.new)
    @server = double("ActionCable server")
    allow(ActionCable).to receive(:server).and_return(@server)
    @logger = double("logger", warn: nil)
    allow(Rails).to receive(:logger).and_return(@logger)
    executor = double("Rails executor")
    allow(executor).to receive(:wrap).and_yield
    allow(Rails).to receive(:application).and_return(double("application", executor: executor))
    load File.expand_path("../18_rails_agent_job/app/jobs/agent_result_job.rb", __dir__)
    load File.expand_path("../18_rails_agent_job/app/jobs/agent_streaming_job.rb", __dir__)
  end

  it "publishes a basic final result on the Job thread without a listener" do
    agent = double("Agent")
    expect(@agents).to receive(:create).with(DemoAgent).and_return(agent)
    expect(agent).to receive(:invoke).with("hello").and_return(output: "answer")
    caller = Thread.current
    expect(@server).to receive(:broadcast).with("chat", {type: "done", output: "answer"}) do
      expect(Thread.current).to equal(caller)
    end
    AgentResultJob.new.perform("DemoAgent", "hello", stream: "chat")
  end

  it "delivers streaming events off the invoking thread with done last" do
    caller = Thread.current
    listener = nil
    agent = double("Agent")
    allow(@agents).to receive(:create) do |_klass, on_event:|
      listener = on_event
      agent
    end
    allow(agent).to receive(:stream) do
      listener.call(OpenStruct.new(type: :token, payload: {content: "A"}))
      listener.call(OpenStruct.new(type: :token, payload: {content: "B"}))
      listener.call(OpenStruct.new(type: :done, payload: {output: "AB"}))
    end
    sent = []
    allow(@server).to receive(:broadcast) do |stream, payload|
      expect(Thread.current).not_to equal(caller)
      expect(stream).to eq("chat")
      sent << payload
    end
    AgentStreamingJob.new.perform("DemoAgent", "hello", stream: "chat")
    expect(sent.last).to eq(type: "done", output: "AB")
    expect(sent.select { |payload| payload[:type] == "token" }.map { |payload| payload[:content] }.join).to eq("AB")
  end

  it "preserves the missing-event fallback when Agent construction fails" do
    failure = RuntimeError.new("cannot create Agent")
    allow(@agents).to receive(:create).and_raise(failure)
    expect(@server).to receive(:broadcast).with("chat", {type: "error", message: failure.message}).once
    expect { AgentStreamingJob.new.perform("DemoAgent", "hello", stream: "chat") }
      .to raise_error { |error| expect(error).to equal(failure) }
  end

  it "does not publish a second error when an error event was accepted" do
    failure = RuntimeError.new("Agent failed")
    listener = nil
    agent = double("Agent")
    allow(@agents).to receive(:create) { |_klass, on_event:|
      listener = on_event
      agent
    }
    allow(agent).to receive(:stream) do
      listener.call(OpenStruct.new(type: :error, payload: {error: failure}))
      raise failure
    end
    expect(@server).to receive(:broadcast).with("chat", {type: "error", message: failure.message}).once
    expect { AgentStreamingJob.new.perform("DemoAgent", "hello", stream: "chat") }
      .to raise_error { |error| expect(error).to equal(failure) }
  end

  it "fails the Job on delivery failure while preserving an earlier Agent error" do
    original = RuntimeError.new("original Agent error")
    allow(@agents).to receive(:create).and_raise(original)
    allow(@server).to receive(:broadcast).and_raise(IOError, "delivery failed")
    expect { AgentStreamingJob.new.perform("DemoAgent", "hello", stream: "chat") }
      .to raise_error { |error| expect(error).to equal(original) }
  end
  context "real Agent lifetime" do
    before do
      allow(Phronomy::Agent).to receive(:open_scope).and_call_original
      klass = Class.new(Phronomy::Agent::Base) do
        agent_definition id: "p6-job-acceptance", version: 1
        model "gpt-4o-mini"
        provider :openai
      end
      stub_const("DemoAgent", klass)
      stub_const("AgentResultJob::AGENTS", {"DemoAgent" => klass})
      @owned = []
      allow(Phronomy::Agent).to receive(:open_scope).and_wrap_original do |original, &block|
        original.call do |agents|
          allow(agents).to receive(:create).and_wrap_original do |create, *args, **kwargs|
            create.call(*args, **kwargs).tap { |agent| @owned << agent }
          end
          block.call(agents)
        end
      end
      ExampleChatStub.new { "answer" }
    end

    it "delivers before releasing the live owner and retains its saved history" do
      expect(@server).to receive(:broadcast).with("chat", {type: "done", output: "answer"}) do
        expect(DemoAgent.get(@owned.first.agent_id)).to equal(@owned.first)
      end
      AgentResultJob.new.perform("DemoAgent", "hello", stream: "chat")
      agent = @owned.fetch(0)
      expect(DemoAgent.get(agent.agent_id)).to be_nil
      expect(agent.persistence.agents.load(agent.agent_id).agent_id).to eq(agent.agent_id)
    end

    it "does not emit an error after done when only cleanup fails" do
      failure = IOError.new("Store check failed")
      expect(@server).to receive(:broadcast).with("chat", {type: "done", output: "answer"}).once do
        allow(@owned.first).to receive(:unload!).and_raise(failure)
      end
      expect {
        AgentResultJob.new.perform("DemoAgent", "hello", stream: "chat")
      }.to raise_error(Phronomy::Agent::ScopeCleanupError) do |error|
        expect(error.failures.fetch(0).fetch(:error)).to equal(failure)
      end
    end
  end

end
