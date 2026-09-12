# frozen_string_literal: true

require "ostruct"
require Rails.root.join("../shared/transcript_messages").expand_path.to_s

class ConversationsController < ApplicationController
  def index
    @agent_id = session[:agent_id]
    @user_id  = session[:user_id]
    if @agent_id
      agent = SecureChatAgent.load(@agent_id, persistence: PhronomyStore.persistence)
      @messages = PhronomyExamples::TranscriptMessages.read(agent).map do |message|
        OpenStruct.new(message)
      end
    else
      @messages = []
    end
  rescue Phronomy::Persistence::NotFoundError
    session[:agent_id] = nil
    @messages = []
  end

  def create
    agent = SecureChatAgent.create(persistence: PhronomyStore.persistence)
    session[:agent_id] = agent.agent_id
    redirect_to root_path
  end

  # Feature D: clear transcript (Journal is preserved; active generation advances).
  def destroy
    # Use session as authority — reject requests targeting another session's agent.
    agent_id = session[:agent_id]
    return redirect_to root_path unless agent_id.present? && params[:id] == agent_id

    agent = SecureChatAgent.load(agent_id, persistence: PhronomyStore.persistence)
    agent.clear_transcript!
    session.delete(:agent_id)
    redirect_to root_path, notice: "Conversation cleared."
  rescue Phronomy::Persistence::NotFoundError
    session.delete(:agent_id)
    redirect_to root_path
  end
end
