# frozen_string_literal: true

class ChatController < ApplicationController
  # GET /
  # Renders the chat UI with a unique session stream key.
  def index
    @session_id = session[:chat_id] ||= SecureRandom.hex(8)
  end

  # POST /chat/send
  # Both display modes return immediately (202 Accepted).
  # The selected job publishes through the same ActionCable protocol.
  def send_message
    input      = params.require(:message)
    session_id = session[:chat_id] ||= SecureRandom.hex(8)
    stream_key = "agent_#{session_id}"

    job_class = case params.fetch(:display_mode, "streaming")
    when "result" then AgentResultJob
    when "streaming" then AgentStreamingJob
    else raise ActionController::BadRequest, "unsupported display_mode"
    end
    job_class.perform_later("DemoAgent", input, stream: stream_key)

    head :accepted
  end
end
