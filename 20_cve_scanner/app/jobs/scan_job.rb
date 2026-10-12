# frozen_string_literal: true

# Each initial/resumed Job owns one notification delivery scope. A saved halt
# or completion remains authoritative even if its final notification fails.
class ScanJob < ApplicationJob
  queue_as :default

  def perform(scan_id, cve_ids)
    self.class.with_scan(scan_id) do |scan, notifications|
      scan.update!(status: "running")
      notifications.publish(type: "status", message: "Starting scan for: #{cve_ids.join(", ")}")
      graph = CveScanner.build_graph(notifications: notifications)
      graph.invoke({cve_ids: cve_ids}, config: {workflow_instance_id: "scan_#{scan_id}"})
    end
  end

  def self.resume(scan_id, approval_type:, approved_commands:, user_note: nil)
    with_scan(scan_id) do |scan, notifications|
      next unless scan.state_json

      state = restore_state(scan.state_json)
      updates = if approval_type == "check"
        {approved_checks: approved_commands, proposed_checks: approved_commands}
      else
        {approved_remediations: approved_commands, proposed_remediations: approved_commands}
      end
      updates[:user_notes] = [user_note.strip] unless user_note.to_s.strip.empty?
      state = state.merge(updates)

      scan.update!(status: "running")
      notifications.publish(type: "status", message: "Resuming with #{approved_commands.size} approved command(s)...")
      CveScanner.build_graph(notifications: notifications).resume(state: state)
    end
  end

  def self.resume_followup(scan_id, message:)
    with_scan(scan_id) do |scan, notifications|
      next unless scan.state_json

      state = restore_state(scan.state_json).merge(followup_request: message)
      scan.update!(status: "running")
      notifications.publish(type: "status", message: "Processing follow-up...")
      CveScanner.build_graph(notifications: notifications).resume(state: state)
    end
  end

  # Reused application policy, not a queue or worker implementation.
  def self.with_scan(scan_id)
    CveScanner::Notifications.open(scan_id: scan_id) do |notifications|
      scan = nil
      payload = begin
        scan = Scan.find(scan_id)
        state = yield scan, notifications
        persist_state(scan, state) if state
      rescue StandardError
        record_failure(scan)
        raise
      end

      # Outside the business/persistence rescue: a delivery error must not
      # overwrite a successfully saved done/awaiting status.
      notifications.publish(payload) if payload
    end
  end

  def self.restore_state(state_data)
    fields = state_data.reject { |key, _| %w[workflow_instance_id phase].include?(key.to_s) }
    state = CveScanner::ScanState.new(**fields.transform_keys(&:to_sym))
    state.set_graph_metadata(
      workflow_instance_id: state_data["workflow_instance_id"],
      phase: state_data["phase"]&.to_sym
    )
    state
  end

  def self.record_failure(scan)
    scan&.update!(status: "error")
  rescue StandardError => secondary
    begin
      Rails.logger.error("Scan failure status could not be saved: #{secondary.class}: #{secondary.message}")
    rescue StandardError
      # Preserve the original business/persistence error even if logging fails.
    end
  end

  def self.persist_state(scan, state)
    # Individual nodes now publish their own informational messages in
    # real-time (gather, check_cve_data, run_checks, run_remediation).
    # We no longer replay state.messages here to avoid duplicate and
    # out-of-order log lines.

    if state.halted?
      # Determine what kind of approval is needed based on current phase.
      pending_phase = state.phase
      if pending_phase == :awaiting_check_approval
        commands = state.proposed_checks
        persisted_state = state.to_h.merge(
          "workflow_instance_id" => state.workflow_instance_id,
          "phase"     => state.phase.to_s
        )
        scan.update!(
          status: "awaiting_check",
          state_json: persisted_state
        )
        {
          type: "awaiting_approval",
          approval_type: "check",
          round: state.check_iteration,
          commands: commands
        }
      elsif pending_phase == :awaiting_remediation_approval
        commands = state.proposed_remediations
        persisted_state = state.to_h.merge(
          "workflow_instance_id" => state.workflow_instance_id,
          "phase"     => state.phase.to_s
        )
        scan.update!(
          status: "awaiting_remediation",
          state_json: persisted_state
        )
        {
          type: "awaiting_approval",
          approval_type: "remediation",
          round: state.remediation_iteration,
          commands: commands
        }
      elsif pending_phase == :awaiting_followup
        # Report is ready; pause and wait for the user's first follow-up message
        persisted_state = state.to_h.merge(
          "workflow_instance_id" => state.workflow_instance_id,
          "phase"     => state.phase.to_s
        )
        scan.update!(
          status: "awaiting_followup",
          state_json: persisted_state
        )
        {type: "awaiting_followup", message: "Scan complete. Ask a follow-up question or type 'done' to finish."}
      end
    else
      # Pipeline completed — build per-CVE detail for UI
      cve_details = state.vulnerability_status.transform_keys(&:to_s).each_with_object({}) do |(cve_id, _), h|
        raw_info = state.cve_infos[cve_id] || state.cve_infos[cve_id.to_sym] || {}
        info = raw_info.transform_keys(&:to_s)
        pkgs = info["packages"]
        pkg_names = pkgs.is_a?(Hash) ? pkgs.keys.first(5) : []
        h[cve_id] = {
          priority:    info["priority"]    || "unknown",
          description: info["description"] || "",
          packages:    pkg_names,
          reasoning:   (state.vulnerability_reasoning[cve_id] || state.vulnerability_reasoning[cve_id.to_sym] || "")
        }
      end

      scan.update!(
        status: "done",
        result_json: {
          vulnerability_status: state.vulnerability_status,
          check_iterations: state.check_iteration,
          remediation_iterations: state.remediation_iteration,
          messages: state.messages
        }
      )
      {
        type: "done",
        vulnerability_status: state.vulnerability_status,
        check_iterations: state.check_iteration,
        remediation_iterations: state.remediation_iteration,
        cve_details: cve_details
      }
    end
  end

  private_class_method :restore_state, :record_failure, :persist_state
end
