# frozen_string_literal: true

require "spec_helper"
require_relative "../shared/transcript_messages"
require_relative "../17_multi_agent_handoff/agents"

RSpec.describe PhronomyExamples::TranscriptMessages do
  ["123", "null", "false", '{"content":"this is user text"}'].each do |input|
    it "preserves #{input.inspect} as literal user text while decoding the assistant envelope" do
      reply = '{"content":"this is literal assistant output"}'
      ExampleChatStub.new { |_request, _index| reply }
      agent = TriageAgent.new
      agent.invoke(input)
      expect(described_class.read(agent)).to eq([
        {"role" => "user", "content" => input},
        {"role" => "assistant", "content" => reply}
      ])
    end
  end

  it "omits assistant messages containing only Tool calls from the text transcript" do
    tool = Class.new(Phronomy::Tool::Base) do
      description "Return a greeting"
      define_method(:execute) { "hello" }
    end
    stub_const("TranscriptGreetingTool", tool)
    agent_class = Class.new(Phronomy::Agent::Base) do
      agent_definition id: "transcript-tool-agent", version: 1
      model "gpt-4o-mini"
      provider :openai
      tools(tool => nil)
    end
    ExampleChatStub.new do |request, index|
      if index.zero?
        ExampleChatStub.tool(request.fetch("tools").first.fetch("function").fetch("name"))
      else
        "The Tool returned a greeting."
      end
    end
    agent = agent_class.new
    agent.invoke("Say hello")
    expect(described_class.read(agent)).to eq([
      {"role" => "user", "content" => "Say hello"},
      {"role" => "assistant", "content" => "The Tool returned a greeting."}
    ])
  end
end
