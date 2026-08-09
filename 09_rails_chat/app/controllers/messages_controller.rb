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

    agent = ChatAgent.load(agent_id, persistence: PhronomyStore.persistence)
    result = agent.invoke(content)

    render json: {reply: result[:output]}
  rescue Phronomy::FilterBlockError => e
    render json: {error: "Blocked by filter: #{e.message}"}, status: :unprocessable_entity
  rescue => e
    Rails.logger.error("ChatAgent error: #{e.class}: #{e.message}")
    render json: {error: "An error occurred. Please try again."}, status: :internal_server_error
  end
end
