# frozen_string_literal: true

class MessagesController < ApplicationController
  def create
    agent_id = session[:agent_id]

    unless agent_id
      render json: {error: "No active conversation. Start a new chat first."}, status: :unprocessable_entity
      return
    end

    content = params[:content].to_s.strip
    if content.empty?
      render json: {error: "Message cannot be blank."}, status: :unprocessable_entity
      return
    end

    result = Phronomy::Agent.open_scope do |agents|
      agent = agents.load(ChatAgent, agent_id, persistence: PhronomyStore.persistence)
      agent.invoke(content)
    end

    render json: {reply: result[:output]}
  rescue Phronomy::AgentBusyError
    render json: {error: "Conversation is busy. Please try again."}, status: :conflict
  rescue Phronomy::FilterBlockError => e
    render json: {error: "Blocked by filter: #{e.message}"}, status: :unprocessable_entity
  rescue => e
    Rails.logger.error("ChatAgent error: #{e.class}: #{e.message}")
    render json: {error: "An error occurred. Please try again."}, status: :internal_server_error
  end
end
