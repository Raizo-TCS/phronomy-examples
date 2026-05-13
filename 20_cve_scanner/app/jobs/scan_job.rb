# frozen_string_literal: true

# Background job that drives the CVE scanner Workflow.
# On halt, it persists state to the DB and broadcasts an approval request.
# On resume, it restores state and continues the workflow.
class ScanJob < ApplicationJob
  queue_as :default

  # Start a new scan from scratch.
  # @param scan_id [Integer]
  # @param cve_ids [Array<String>]
  def perform(scan_id, cve_ids)
    scan = Scan.find(scan_id)
    scan.update!(status: "running")
    broadcast(scan_id, {type: "status", message: "Starting scan for: #{cve_ids.join(", ")}"})

    graph = CveScanner.build_graph(scan_id: scan_id)
    state = graph.invoke({cve_ids: cve_ids}, config: {thread_id: "scan_#{scan_id}"})

    self.class.handle_state(scan, state)
  rescue StandardError => e
    scan&.update!(status: "error")
    broadcast(scan_id, {type: "error", message: e.message})
    raise
  end

  # Resume after user approves commands.
  # @param scan_id [Integer]
  # @param approval_type [String] "check" or "remediation"
  # @param approved_commands [Array<String>]
  def self.resume(scan_id, approval_type:, approved_commands:, user_note: nil)
    scan = Scan.find(scan_id)
    state_data = scan.state_json
    return unless state_data

    graph = CveScanner.build_graph(scan_id: scan_id)

    # Restore state from persisted hash
    meta_keys = %w[thread_id phase]
    field_attrs = state_data
      .reject { |k, _| meta_keys.include?(k.to_s) }
      .transform_keys(&:to_sym)

    state = CveScanner::ScanState.new(**field_attrs)
    state.set_graph_metadata(
      thread_id: state_data["thread_id"],
      phase:     state_data["phase"]&.to_sym
    )

    # Inject approved commands into state
    updates = if approval_type == "check"
      {approved_checks: approved_commands, proposed_checks: approved_commands}
    else
      {approved_remediations: approved_commands, proposed_remediations: approved_commands}
    end
    updates[:user_notes] = [user_note.strip] if user_note.to_s.strip.length > 0
    state = state.merge(updates)

    scan.update!(status: "running")
    broadcast(scan_id, {type: "status", message: "Resuming with #{approved_commands.size} approved command(s)..."})

    new_state = graph.resume(state: state)
    handle_state(scan, new_state)
  rescue StandardError => e
    scan&.update!(status: "error")
    broadcast(scan_id, {type: "error", message: e.message})
    raise
  end

  # Resume after the user submits a post-report follow-up message.
  # @param scan_id [Integer]
  # @param message [String] the user's question or command
  def self.resume_followup(scan_id, message:)
    scan = Scan.find(scan_id)
    state_data = scan.state_json
    return unless state_data

    graph = CveScanner.build_graph(scan_id: scan_id)

    meta_keys = %w[thread_id phase]
    field_attrs = state_data
      .reject { |k, _| meta_keys.include?(k.to_s) }
      .transform_keys(&:to_sym)

    state = CveScanner::ScanState.new(**field_attrs)
    state.set_graph_metadata(
      thread_id: state_data["thread_id"],
      phase:     state_data["phase"]&.to_sym
    )
    state = state.merge(followup_request: message)

    scan.update!(status: "running")
    broadcast(scan_id, {type: "status", message: "Processing follow-up..."})

    new_state = graph.resume(state: state)
    handle_state(scan, new_state)
  rescue StandardError => e
    scan&.update!(status: "error")
    broadcast(scan_id, {type: "error", message: e.message})
    raise
  end

  private

  def self.handle_state(scan, state)
    scan_id = scan.id

    # Broadcast each new message from the pipeline
    state.messages.last(20).each do |msg|
      broadcast(scan_id, {type: "log", message: msg})
    end

    if state.halted?
      # Determine what kind of approval is needed based on current phase.
      pending_phase = state.phase
      if pending_phase == :awaiting_check_approval
        commands = state.proposed_checks
        persisted_state = state.to_h.merge(
          "thread_id" => state.thread_id,
          "phase"     => state.phase.to_s
        )
        scan.update!(
          status: "awaiting_check",
          state_json: persisted_state
        )
        broadcast(scan_id, {
          type: "awaiting_approval",
          approval_type: "check",
          round: state.check_iteration,
          commands: commands
        })
      elsif pending_phase == :awaiting_remediation_approval
        commands = state.proposed_remediations
        persisted_state = state.to_h.merge(
          "thread_id" => state.thread_id,
          "phase"     => state.phase.to_s
        )
        scan.update!(
          status: "awaiting_remediation",
          state_json: persisted_state
        )
        broadcast(scan_id, {
          type: "awaiting_approval",
          approval_type: "remediation",
          round: state.remediation_iteration,
          commands: commands
        })
      elsif pending_phase == :awaiting_followup
        # Report is ready; pause and wait for the user's first follow-up message
        persisted_state = state.to_h.merge(
          "thread_id" => state.thread_id,
          "phase"     => state.phase.to_s
        )
        scan.update!(
          status: "awaiting_followup",
          state_json: persisted_state
        )
        broadcast(scan_id, {type: "awaiting_followup", message: "Scan complete. Ask a follow-up question or type 'done' to finish."})
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
      broadcast(scan_id, {
        type: "done",
        vulnerability_status: state.vulnerability_status,
        check_iterations: state.check_iteration,
        remediation_iterations: state.remediation_iteration,
        cve_details: cve_details
      })
    end
  end

  def self.broadcast(scan_id, payload)
    ScanChannel.broadcast(scan_id, payload)
  end

  def broadcast(scan_id, payload)
    self.class.broadcast(scan_id, payload)
  end
end
