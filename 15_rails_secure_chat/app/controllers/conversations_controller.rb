# frozen_string_literal: true

require "ostruct"
require Rails.root.join("../shared/transcript_messages").expand_path.to_s

class ConversationsController < ApplicationController
  def index
    @agent_id = session[:agent_id]
    @user_id  = session[:user_id]
    Phronomy::Agent.open_scope do |agents|
      if @agent_id
        begin
          agent = agents.load(SecureChatAgent, @agent_id, persistence: PhronomyStore.persistence)
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
      agents.create(SecureChatAgent, persistence: PhronomyStore.persistence).agent_id
    end
    redirect_to root_path
  rescue Phronomy::AgentBusyError
    render json: {error: "Conversation is busy. Please try again."}, status: :conflict
  end

  # Feature D: clear transcript (Journal is preserved; active generation advances).
  def destroy
    # Use session as authority — reject requests targeting another session's agent.
    agent_id = session[:agent_id]
    return redirect_to root_path unless agent_id.present? && params[:id] == agent_id

    Phronomy::Agent.open_scope do |agents|
      begin
        agent = agents.load(SecureChatAgent, agent_id, persistence: PhronomyStore.persistence)
      rescue Phronomy::AgentNotFoundError => error
        raise unless error.agent_id == agent_id

        session.delete(:agent_id)
        return redirect_to root_path
      end
      agent.clear_transcript!
    end
    session.delete(:agent_id)
    redirect_to root_path, notice: "Conversation cleared."
  rescue Phronomy::AgentBusyError
    render json: {error: "Conversation is busy. Please try again."}, status: :conflict
  end
end
