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

    agent = SecureChatAgent.load(agent_id, persistence: PhronomyStore.persistence)

    last_activity = session[:last_agent_activity_at]
    if last_activity && (Time.now.to_i - last_activity.to_i) > PHRONOMY_MEMORY_TTL
      agent.clear_transcript!
    end
    session[:last_agent_activity_at] = Time.now.to_i

    result = agent.invoke(
      content,
      config: {
        user_id: session[:user_id]
      }
    )

    render json: {reply: result[:output]}
  rescue Phronomy::FilterBlockError => e
    render json: {error: "Blocked: #{e.message}"}, status: :unprocessable_entity
  rescue => e
    Rails.logger.error("SecureChatAgent error: #{e.class}: #{e.message}")
    render json: {error: "An error occurred. Please try again."}, status: :internal_server_error
  end
end
