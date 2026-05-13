# frozen_string_literal: true

# Enqueued when the user approves commands for a halted scan.
class ScanResumeJob < ApplicationJob
  queue_as :default

  # @param scan_id [Integer]
  # @param approval_type [String] "check" or "remediation"
  # @param approved_commands [Array<String>]
  # @param user_note [String, nil] optional message from the operator
  def perform(scan_id, approval_type:, approved_commands:, user_note: nil)
    ScanJob.resume(scan_id, approval_type: approval_type, approved_commands: approved_commands, user_note: user_note)
  end
end
