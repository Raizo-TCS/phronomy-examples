# frozen_string_literal: true

# ActionCable channel for real-time scan progress updates.
# Clients subscribe with { scan_id: "..." } to receive pipeline events.
class ScanChannel < ApplicationCable::Channel
  def subscribed
    stream_from "scan_#{params[:scan_id]}"
  end

  def unsubscribed
    # nothing to clean up
  end

  # Broadcast a pipeline event to all subscribers for the given scan.
  def self.broadcast(scan_id, payload)
    ActionCable.server.broadcast("scan_#{scan_id}", payload)
  end
end
