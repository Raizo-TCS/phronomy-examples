# frozen_string_literal: true

class MessagesController < ApplicationController
  def create
    thread_id = session[:thread_id]

    unless thread_id
      render json: { error: "No active conversation. Start a new chat first." }, status: :unprocessable_entity
      return
    end

    content = params[:content].to_s.strip
    if content.empty?
      render json: { error: "Message cannot be blank." }, status: :unprocessable_entity
      return
    end

    # Feature D: strip messages older than TTL before building context.
    purge_stale_messages(thread_id)

    # Feature D: ConversationManager (legacy interface, compatible with model_class alone).
    memory = build_memory

    # Feature B: propagate session user_id to the tracer span.
    result = SecureChatAgent.new.invoke(
      content,
      config: {
        memory:    memory,
        thread_id: thread_id,
        user_id:   session[:user_id]
      }
    )

    render json: { reply: result[:output] }
  rescue Phronomy::GuardrailError => e
    # Feature A: guardrail blocked the input.
    render json: { error: "Blocked: #{e.message}" }, status: :unprocessable_entity
  rescue => e
    Rails.logger.error("SecureChatAgent error: #{e.class}: #{e.message}")
    render json: { error: "An error occurred. Please try again." }, status: :internal_server_error
  end
end
