# frozen_string_literal: true

require Rails.root.join("../shared/transcript_messages").expand_path.to_s

require "ostruct"

class ConversationsController < ApplicationController
  def index
    @agent_id = session[:agent_id]
    if @agent_id
      agent = ChatAgent.load(@agent_id, persistence: PhronomyStore.persistence)
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
    agent = ChatAgent.create(persistence: PhronomyStore.persistence)
    session[:agent_id] = agent.agent_id
    redirect_to root_path
  end
end
