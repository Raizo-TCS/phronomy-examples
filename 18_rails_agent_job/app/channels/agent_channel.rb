# frozen_string_literal: true

# ActionCable channel that clients subscribe to in order to receive
# real-time streaming events from Phronomy::Rails::AgentJob.
#
# Subscription stream key: "agent_<session_id>"
# Broadcast payloads:
#   { type: "token",  content: "..."  }
#   { type: "done",   output:  "..."  }
#   { type: "error",  message: "..."  }
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
