# frozen_string_literal: true

require Rails.root.join("../shared/transcript_messages").expand_path.to_s

require "ostruct"

class ConversationsController < ApplicationController
  def index
    @agent_id = session[:agent_id]
    Phronomy::Agent.open_scope do |agents|
      if @agent_id
        begin
          agent = agents.load(ChatAgent, @agent_id, persistence: PhronomyStore.persistence)
        rescue Phronomy::AgentNotFoundError => error
          raise unless error.agent_id == @agent_id

          session[:agent_id] = nil
          @messages = []
          return
        end
        @messages = PhronomyExamples::TranscriptMessages.read(agent).map do |message|
          OpenStruct.new(message)
        end
      else
        @messages = []
      end
    end
  rescue Phronomy::AgentBusyError
    render json: {error: "Conversation is busy. Please try again."}, status: :conflict
  end

  def create
    session[:agent_id] = Phronomy::Agent.open_scope do |agents|
      agents.create(ChatAgent, persistence: PhronomyStore.persistence).agent_id
    end
    redirect_to root_path
  rescue Phronomy::AgentBusyError
    render json: {error: "Conversation is busy. Please try again."}, status: :conflict
  end
end
