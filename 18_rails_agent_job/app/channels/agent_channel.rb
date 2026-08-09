# frozen_string_literal: true

# ActionCable channel used by the application-owned AgentStreamingJob.
#
# Phronomy provides Agent#stream. The Rails application decides how those
# stream events are transported to clients; this example uses ActionCable.
#
# Subscription stream key: "agent_<session_id>"
# Broadcast payloads:
#   { type: "token",       content: "..." }
#   { type: "tool_call",   tool:    "..." }
#   { type: "tool_result" }
#   { type: "done",        output:  "..." }
#   { type: "error",       message: "..." }
class AgentChannel < ApplicationCable::Channel
  def subscribed
    stream_from stream_key
  end

  def unsubscribed
    # nothing to clean up
  end

  private

  def stream_key
    "agent_#{params[:session_id]}"
  end
end
