# frozen_string_literal: true

require "spec_helper"
require "pathname"
require_relative "../shared/transcript_messages"

# Only Rails routing/rendering is doubled. Agents, persistence, Workflow, Tasks
# and HTTP protocol handling are real.
RSpec.describe "Request-owned Agent lifetimes" do
  ["09_rails_chat", "15_rails_secure_chat"].each do |app|
    context app do
      let(:store) { Phronomy::PersistenceComposition.in_memory.agent }

      before do
        root = Pathname.new(File.expand_path("../#{app}", __dir__))
        stub_const("Rails", Module.new)
        allow(Rails).to receive(:root).and_return(root)
        allow(Rails).to receive(:logger).and_return(double("logger", error: nil))
        base = Class.new do
          attr_accessor :session, :params, :response
          def render(**response) = self.response = response
          def redirect_to(*) = nil
          def root_path = "/"
        end
        stub_const("ApplicationController", base)
        stub_const("ConversationsController", Class.new(base))
        stub_const("MessagesController", Class.new(base))
        @agent_class = Class.new(Phronomy::Agent::Base) do
          agent_definition id: "p6-request-acceptance", version: 1
          model "gpt-4o-mini"
          provider :openai
        end
        stub_const(app.start_with?("09") ? "ChatAgent" : "SecureChatAgent", @agent_class)
        stub_const("PhronomyStore", Module.new)
        allow(PhronomyStore).to receive(:persistence).and_return(store)
        stub_const("PHRONOMY_MEMORY_TTL", 30)
        load root.join("app/controllers/conversations_controller.rb")
        load root.join("app/controllers/messages_controller.rb")
        @session = {user_id: "test-user"}
        @conversations = ConversationsController.new
        @conversations.session = @session
        @messages = MessagesController.new
        @messages.session = @session
        @messages.params = {content: "first question"}
        @conversations.create
        @id = @session.fetch(:agent_id)
        expect(@agent_class.get(@id)).to be_nil
      end

      it "keeps transcript and session identity across fresh request incarnations" do
        stub = ExampleChatStub.new { |_body, index| "answer #{index + 1}" }
        @messages.create
        expect(@messages.response).to eq(json: {reply: "answer 1"})
        expect(@agent_class.get(@id)).to be_nil
        @conversations.index
        expect(@conversations.instance_variable_get(:@messages).map(&:content))
          .to eq(["first question", "answer 1"])
        expect(@agent_class.get(@id)).to be_nil
        @messages.params = {content: "second question"}
        @messages.create
        expect(@messages.response).to eq(json: {reply: "answer 2"})
        expect(@session[:agent_id]).to eq(@id)
        expect(@agent_class.get(@id)).to be_nil
        texts = stub.calls.last.fetch("messages").map { |message| message["content"] }
        expect(texts).to include("first question", "answer 1", "second question")
      end

      it "returns conflict without adopting another request's live owner" do
        Phronomy::Agent.open_scope do |other_request|
          owner = other_request.load(@agent_class, @id, persistence: store)
          @messages.create
          expect(@messages.response).to include(status: :conflict)
          expect(@agent_class.get(@id)).to equal(owner)
          expect(@session[:agent_id]).to eq(@id)
        end
        expect(@agent_class.get(@id)).to be_nil
      end

      it "releases a failed request without deleting the durable conversation" do
        ExampleChatStub.new { raise IOError, "provider unavailable" }
        @messages.create
        expect(@messages.response).to include(status: :internal_server_error)
        expect(@agent_class.get(@id)).to be_nil
        expect(store.agents.load(@id).agent_id).to eq(@id)
        expect(@session[:agent_id]).to eq(@id)
      end
    end
  end

  context "summary Workflow" do
    before do
      stub_const("LLM_MODEL", "gpt-4o-mini")
      load File.expand_path("../15_rails_secure_chat/app/graphs/summarization_graph.rb", __dir__)
    end

    it "waits for a final summary and releases the async-created child" do
      stub = ExampleChatStub.new { "A concise summary." }
      child = nil
      result = Phronomy::Agent.open_scope do |agents|
        allow(agents).to receive(:create_async).and_wrap_original do |original, *args, **kwargs|
          original.call(*args, **kwargs).map { |agent| child = agent }
        end
        SummarizationGraph.compile(agents: agents).invoke({messages: [{"role" => "user", "content" => "hello"}]})
      end
      expect(result.summary).to eq("A concise summary.")
      expect(result).not_to be_halted
      expect(stub.calls.length).to eq(1)
      expect(SummarizationGraph::SummarizationAgent.get(child.agent_id)).to be_nil
    end

    it "propagates failure instead of returning an empty successful summary" do
      ExampleChatStub.new { raise IOError, "summary unavailable" }
      child = nil
      expect {
        Phronomy::Agent.open_scope do |agents|
          allow(agents).to receive(:create_async).and_wrap_original do |original, *args, **kwargs|
            original.call(*args, **kwargs).map { |agent| child = agent }
          end
          SummarizationGraph.compile(agents: agents).invoke({messages: [{"role" => "user", "content" => "hello"}]})
        end
      }.to raise_error(Faraday::ConnectionFailed, /summary unavailable/)
      expect(child).not_to be_nil
      expect(SummarizationGraph::SummarizationAgent.get(child.agent_id)).to be_nil
    end
  end
end
