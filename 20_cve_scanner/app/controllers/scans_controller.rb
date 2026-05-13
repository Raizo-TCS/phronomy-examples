# frozen_string_literal: true

class ScansController < ApplicationController
  # GET /
  def index
    @scan = nil
  end

  # POST /scans
  # Creates a new scan and enqueues the background job.
  def create
    raw = params.require(:cve_ids)
    cve_ids = raw.split(/[\s,]+/).map(&:strip).reject(&:empty?).uniq

    scan = Scan.create!(
      cve_ids: cve_ids,
      status: "pending"
    )

    ScanJob.perform_later(scan.id, cve_ids)

    render json: {scan_id: scan.id}, status: :accepted
  end

  # GET /scans/:id
  def show
    scan = Scan.find(params[:id])
    render json: {
      id:                   scan.id,
      status:               scan.status,
      vulnerability_status: scan.result_json&.dig("vulnerability_status") || {},
      messages:             scan.result_json&.dig("messages") || []
    }
  end

  # POST /scans/:id/approve
  # Resumes the halted graph with user-approved commands.
  def approve
    scan = Scan.find(params[:id])
    approval_type    = params.require(:approval_type)  # "check" or "remediation"
    approved_commands = Array(params[:approved_commands])

    unless %w[check remediation].include?(approval_type)
      return render json: {error: "Invalid approval_type"}, status: :unprocessable_entity
    end

    user_note = params[:user_note].to_s.strip.presence
    ScanResumeJob.perform_later(scan.id, approval_type: approval_type, approved_commands: approved_commands, user_note: user_note)

    head :accepted
  end

  # POST /scans/:id/note
  # Injects a standalone user message into the scan context without resuming.
  def note
    scan = Scan.find(params[:id])
    text = params.require(:note).to_s.strip
    return head :unprocessable_entity if text.empty?

    # Append note to persisted state_json so the next LLM round picks it up
    if (state_data = scan.state_json)
      existing = Array(state_data["user_notes"])
      scan.update_column(:state_json, state_data.merge("user_notes" => existing + [text]))
    end

    # Broadcast so the UI shows the message immediately
    ScanChannel.broadcast(scan.id, {type: "user_note", content: text})

    # Respond via LLM asynchronously when scan is done or waiting for approval
    if %w[done awaiting_check awaiting_remediation].include?(scan.status)
      ScanChatJob.perform_later(scan.id, text)
    end

    head :accepted
  end

  # POST /scans/:id/followup
  # Resumes the halted graph with the user's post-report question or command.
  def followup
    scan = Scan.find(params[:id])
    message = params.require(:message).to_s.strip
    return render json: {error: "message is required"}, status: :unprocessable_entity if message.empty?
    return render json: {error: "scan is not awaiting a follow-up"}, status: :unprocessable_entity unless scan.status == "awaiting_followup"

    ScanFollowupJob.perform_later(scan.id, message)
    head :accepted
  end
end