# frozen_string_literal: true

class ChatController < ApplicationController
  # GET /
  # Renders the chat UI with a unique session stream key.
  def index
    @session_id = session[:chat_id] ||= SecureRandom.hex(8)
  end

  # POST /chat/send
  # Enqueues the streaming agent job and returns immediately (202 Accepted).
  # The client receives tokens via ActionCable once the job starts.
  def send_message
    input      = params.require(:message)
    session_id = session[:chat_id] ||= SecureRandom.hex(8)
    stream_key = "agent_#{session_id}"

    AgentStreamingJob.perform_later("DemoAgent", input, stream: stream_key)

    head :accepted
  end
end
