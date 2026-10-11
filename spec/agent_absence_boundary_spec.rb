# frozen_string_literal: true

require "spec_helper"
require "pathname"
require_relative "../shared/transcript_messages"

# Controller unit acceptance: only Rails plumbing is doubled. These tests are
# also run in the root bundle; CI separately boots both real Rails applications.
RSpec.describe "Application Agent absence handling" do
  ["09_rails_chat", "15_rails_secure_chat"].each do |example|
    context example do
      before do
        root = Pathname.new(File.expand_path("../#{example}", __dir__))
        stub_const("Rails", Module.new)
        allow(Rails).to receive(:root).and_return(root)
        base = Class.new do
          attr_accessor :session
        end
        stub_const("ApplicationController", base)
        stub_const("ConversationsController", Class.new(base))
        @agent_class = Class.new(Phronomy::Agent::Base)
        stub_const(example == "09_rails_chat" ? "ChatAgent" : "SecureChatAgent", @agent_class)
        stub_const("PhronomyStore", Module.new)
        allow(PhronomyStore).to receive(:persistence).and_return(:store)
        load root.join("app/controllers/conversations_controller.rb")
        @controller = ConversationsController.new
        @controller.session = {agent_id: "requested", user_id: "user"}
      end

      it "clears only the requested absent Agent" do
        allow(@agent_class).to receive(:load).and_raise(Phronomy::AgentNotFoundError.new(agent_id: "requested"))
        @controller.index
        expect(@controller.session[:agent_id]).to be_nil
        expect(@controller.instance_variable_get(:@messages)).to eq([])
      end

      it "does not hide absence of another Agent inside restoration" do
        original = Phronomy::AgentNotFoundError.new(agent_id: "other")
        allow(@agent_class).to receive(:load).and_raise(original)
        expect { @controller.index }.to raise_error { |error| expect(error).to equal(original) }
        expect(@controller.session[:agent_id]).to eq("requested")
      end

      it "does not turn a missing transcript into an empty conversation" do
        agent = double("loaded Agent")
        allow(@agent_class).to receive(:load).and_return(agent)
        missing = Phronomy::Persistence::NotFoundError.new("missing transcript")
        allow(PhronomyExamples::TranscriptMessages).to receive(:read).with(agent).and_raise(missing)
        expect { @controller.index }.to raise_error { |error| expect(error).to equal(missing) }
        expect(@controller.session[:agent_id]).to eq("requested")
      end
    end
  end
end
