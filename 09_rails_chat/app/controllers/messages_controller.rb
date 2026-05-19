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

    messages = PhronomyMessage.load_messages(thread_id)
    result = ChatAgent.new.invoke(content, messages: messages, thread_id: thread_id)
    PhronomyMessage.save_messages(thread_id, result[:messages])

    render json: { reply: result[:output] }
  rescue Phronomy::GuardrailError => e
    render json: { error: "Blocked by guardrail: #{e.message}" }, status: :unprocessable_entity
  rescue => e
    Rails.logger.error("ChatAgent error: #{e.class}: #{e.message}")
    render json: { error: "An error occurred. Please try again." }, status: :internal_server_error
  end
end
