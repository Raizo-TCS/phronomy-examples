# frozen_string_literal: true

# Dispatched when the operator sends a follow-up question after a scan is done.
# Calls ChatAgent with the full scan context and streams the response back.
class ScanChatJob < ApplicationJob
  queue_as :default

  def perform(scan_id, question)
    scan = Scan.find(scan_id)
    context = build_context(scan, question)

    agent = CveScanner::ChatAgent.new
    accumulated = +""

    ScanChannel.broadcast(scan_id, {
      type: "chat_turn_start",
      role: "ChatAgent",
      prompt_preview: question.slice(0, 200)
    })

    result = agent.stream(context) do |event|
      next unless event.type == :token

      token = event.payload[:content].to_s
      accumulated << token
      ScanChannel.broadcast(scan_id, {type: "llm_token", role: "ChatAgent", token: token})
    end

    raw = (result.is_a?(Array) ? result.first : result)&.dig(:output).to_s.strip
    content = raw.empty? ? accumulated : raw
    ScanChannel.broadcast(scan_id, {type: "chat_turn_done", role: "ChatAgent", content: content})
  rescue StandardError => e
    ScanChannel.broadcast(scan_id, {type: "error", message: e.message})
  end

  private

  def build_context(scan, question)
    state = scan.state_json || {}
    lines = []

    # --- Vulnerability summary ---
    vuln_status = state["vulnerability_status"] || {}
    unless vuln_status.empty?
      lines << "=== Scan Results ==="
      vuln_status.each do |cve_id, status|
        lines << "#{cve_id}: #{status}"
        reasoning = state.dig("vulnerability_reasoning", cve_id).to_s.strip
        lines << "  Assessment: #{reasoning}" unless reasoning.empty?
      end
    end

    # --- Check history ---
    check_history = Array(state["check_history"])
    unless check_history.empty?
      lines << ""
      lines << "=== Check Commands Executed ==="
      check_history.each do |h|
        lines << "Command: #{h["cmd"] || h[:cmd]}"
        output = (h["output"] || h[:output]).to_s
        lines << "Output (truncated): #{output.slice(0, 600)}"
      end
    end

    # --- Remediation history ---
    rem_history = Array(state["remediation_history"])
    unless rem_history.empty?
      lines << ""
      lines << "=== Remediation Commands Executed ==="
      rem_history.each do |h|
        lines << "Command: #{h["cmd"] || h[:cmd]}"
        output = (h["output"] || h[:output]).to_s
        lines << "Output (truncated): #{output.slice(0, 300)}"
      end
    end

    # --- Prior operator notes ---
    user_notes = Array(state["user_notes"])
    unless user_notes.empty?
      lines << ""
      lines << "=== Previous Operator Notes ==="
      user_notes.each { |n| lines << n }
    end

    lines << ""
    lines << "=== Operator Question ==="
    lines << question
    lines.join("\n")
  end
end
