# frozen_string_literal: true

class ConversationsController < ApplicationController
  def index
    @agent_id = session[:agent_id]
    @user_id  = session[:user_id]
    if @agent_id
      agent = SecureChatAgent.load(@agent_id, persistence: PhronomyStore.persistence)
      @messages = agent.transcript.filter_map do |record|
        next unless %i[user assistant].include?(record.role)
        content_raw = PhronomyStore.persistence.contents.fetch_text(record.content_ref)
        content_text = begin
          JSON.parse(content_raw)["content"] || content_raw
        rescue JSON::ParserError
          content_raw
        end
        OpenStruct.new(role: record.role.to_s, content: content_text)
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
    agent_id = params[:id]
    if agent_id.present?
      agent = SecureChatAgent.load(agent_id, persistence: PhronomyStore.persistence)
      agent.clear_transcript!
      session.delete(:agent_id)
    end
    redirect_to root_path, notice: "Conversation cleared."
  rescue Phronomy::Persistence::NotFoundError
    session.delete(:agent_id)
    redirect_to root_path
  end
end
