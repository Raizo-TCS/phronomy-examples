# frozen_string_literal: true

# Enqueued when the user submits a post-report follow-up message.
class ScanFollowupJob < ApplicationJob
  queue_as :default

  # @param scan_id [Integer]
  # @param message [String] the user's question or command
  def perform(scan_id, message)
    ScanJob.resume_followup(scan_id, message: message)
  end
end
