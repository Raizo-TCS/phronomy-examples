# frozen_string_literal: true

require "json"

# Builds and returns the compiled CVE scanner Workflow.
module CveScanner
  MAX_LOOP_ITERATIONS = 10

  # Helper: call an agent with streaming, broadcast tokens via ActionCable,
  # and return the parsed JSON response.
  # @param agent_class [Class] Phronomy::Agent::Base subclass
  # @param prompt      [String] user message sent to the agent
  # @param scan_id     [Integer, nil] if set, tokens are broadcast as :llm_token
  # @param role        [String] label shown in the UI chat (e.g. "CveAnalyst")
  def self.call_agent_json(agent_class, prompt, scan_id: nil, role: agent_class.name.split("::").last)
    # Mock mode: skip the real LLM and return deterministic fixed responses.
    # Activate by setting CVE_SCANNER_MOCK_LLM=1 before starting the server.
    return mock_agent_response(agent_class, prompt, scan_id: scan_id, role: role) if ENV["CVE_SCANNER_MOCK_LLM"].present?

    agent = agent_class.new
    accumulated = +""
    last_tool_name = +"unknown"

    if scan_id
      ScanChannel.broadcast(scan_id, {type: "chat_turn_start", role: role, prompt_preview: prompt.slice(0, 200)})
    end

    result = agent.stream(prompt) do |event|
      case event.type
      when :token
        token = event.payload[:content].to_s
        accumulated << token
        ScanChannel.broadcast(scan_id, {type: "llm_token", role: role, token: token}) if scan_id
      when :tool_call
        tc = event.payload[:tool_call]
        last_tool_name.replace(tc.respond_to?(:name) ? tc.name.to_s : "tool")
        args_str = tc.respond_to?(:arguments) ? tc.arguments.inspect.slice(0, 120) : ""
        ScanChannel.broadcast(scan_id, {type: "log", subtype: "tool_call",
          message: "#{role} \u2192 calling #{last_tool_name}: #{args_str}"}) if scan_id
      when :tool_result
        # result payload is the raw String returned by tool.call(args)
        tr_str = event.payload[:tool_result].to_s
        ScanChannel.broadcast(scan_id, {type: "log", subtype: "tool_result",
          message: "#{role} \u2190 #{last_tool_name} result (#{tr_str.length} chars)"}) if scan_id
      when :done
        # final result captured below
      end
    end

    raw = (result.is_a?(Array) ? result.first : result)&.dig(:output).to_s.strip
    # When the result object carries no output (some Phronomy stream backends
    # return the final text only via :token events), fall back to the tokens
    # we accumulated ourselves so the answer is never silently lost.
    raw = accumulated.strip if raw.empty?
    # Strip leading/trailing markdown code fences produced by some LLMs.
    raw = raw.gsub(/\A```(?:json)?\s*/i, "").gsub(/\s*```\z/, "").strip
    # If the LLM added prose around the JSON, extract the first {...} block.
    # Also attempt to repair truncated JSON by appending missing closing braces,
    # which can happen when a model stops generating before the final "}}".
    parsed = begin
      JSON.parse(raw)
    rescue JSON::ParserError
      m = raw.match(/\{.*\}/m)
      if m
        candidate = m[0]
        repaired = nil
        (0..5).each do |n|
          begin
            repaired = JSON.parse(candidate + ("}" * n))
            break
          rescue JSON::ParserError
            next
          end
        end
        repaired
      end
    end
    if parsed
      # Broadcast clean, normalised JSON so the client never has to guess the format.
      ScanChannel.broadcast(scan_id, {type: "chat_turn_done", role: role, content: parsed.to_json}) if scan_id
      parsed
    else
      # Completely unparseable — fall back to raw accumulated text.
      ScanChannel.broadcast(scan_id, {type: "chat_turn_done", role: role, content: accumulated}) if scan_id
      {"decision" => "need_more", "proposed_commands" => [], "error" => "json_parse_failed"}
    end
  end

  def self.build_graph(scan_id: nil)
    # Capture scan_id in node lambdas via closure.
    gather_node      = ->(s) { node_gather_scan_info(s, scan_id: scan_id) }
    check_cve_node   = ->(s) { node_check_cve_data(s, scan_id: scan_id) }
    propose_checks   = ->(s) { node_propose_checks(s, scan_id: scan_id) }
    run_checks       = ->(s) { node_run_checks(s, scan_id: scan_id) }
    eval_checks      = ->(s) { node_evaluate_checks(s, scan_id: scan_id) }
    propose_remed    = ->(s) { node_propose_remediation(s, scan_id: scan_id) }
    run_remed        = ->(s) { node_run_remediation(s, scan_id: scan_id) }
    eval_remed       = ->(s) { node_evaluate_remediation(s, scan_id: scan_id) }
    report_node      = ->(s) { node_report(s, scan_id: scan_id) }
    followup_node    = ->(s) { node_handle_followup(s, scan_id: scan_id) }

    Phronomy::Workflow.define(CveScanner::ScanState) do
      initial :gather_scan_info

      # ── Action states ────────────────────────────────────────────────────
      state :gather_scan_info,      action: gather_node
      state :check_cve_data,        action: check_cve_node
      state :propose_checks,        action: propose_checks
      state :run_checks,            action: run_checks
      state :evaluate_checks,       action: eval_checks
      state :propose_remediation,   action: propose_remed
      state :run_remediation,       action: run_remed
      state :evaluate_remediation,  action: eval_remed
      state :report,                action: report_node
      state :handle_followup,       action: followup_node

      # ── Wait states (human-in-the-loop pause points) ──────────────────────
      wait_state :awaiting_check_approval
      wait_state :awaiting_remediation_approval
      wait_state :awaiting_followup

      # ── Edges ─────────────────────────────────────────────────────────────
      after :gather_scan_info, to: :check_cve_data
      after :run_checks,       to: :evaluate_checks
      after :run_remediation,  to: :evaluate_remediation
      after :report,           to: :awaiting_followup

      # Skip to :report when all CVEs have no package data.
      event :route, from: :check_cve_data,
        guard: ->(s) {
          checkable = s.cve_ids.reject { |id| %w[not_found no_packages].include?(s.vulnerability_status[id]) }
          checkable.empty?
        }, to: :report
      event :route, from: :check_cve_data, to: :propose_checks

      # CHECK LOOP: agent may decide "done" in :propose_checks (skips checks).
      event :route, from: :propose_checks,
        guard: ->(s) { s.check_decision == "need_more" }, to: :awaiting_check_approval
      event :route, from: :propose_checks, to: :report
      event :approve_checks, from: :awaiting_check_approval, to: :run_checks

      event :route, from: :evaluate_checks,
        guard: ->(s) { s.check_decision == "need_more" }, to: :propose_checks
      event :route, from: :evaluate_checks, to: :report

      # REMEDIATION LOOP
      event :route, from: :propose_remediation,
        guard: ->(s) { s.remediation_decision == "need_more" }, to: :awaiting_remediation_approval
      event :route, from: :propose_remediation, to: :report
      event :approve_remediation, from: :awaiting_remediation_approval, to: :run_remediation

      event :route, from: :evaluate_remediation,
        guard: ->(s) { s.remediation_decision == "need_more" }, to: :propose_remediation
      event :route, from: :evaluate_remediation, to: :report

      # FOLLOW-UP LOOP: after report wait for user questions.
      event :submit_followup, from: :awaiting_followup, to: :handle_followup

      event :route, from: :handle_followup,
        guard: ->(s) { s.followup_decision == "answered" },      to: :awaiting_followup
      event :route, from: :handle_followup,
        guard: ->(s) { s.followup_decision == "reinvestigate" }, to: :gather_scan_info
      event :route, from: :handle_followup,
        guard: ->(s) { s.followup_decision == "remediate" },     to: :propose_remediation
      event :route, from: :handle_followup,
        guard: ->(s) { s.followup_decision == "report" },        to: :report
      event :route, from: :handle_followup, to: :__finish__
    end
  end

  # ── Node implementations ─────────────────────────────────────────────────

  def self.node_gather_scan_info(state, scan_id: nil)
    # Validate CVE IDs
    valid   = state.cve_ids.select { |id| id.match?(/\ACVE-\d{4}-\d{4,}\z/i) }
    invalid = state.cve_ids - valid
    msgs    = valid.any? ? [] : ["ERROR: No valid CVE IDs provided."]
    msgs   << "Skipping invalid IDs: #{invalid.join(", ")}" if invalid.any?

    # Detect OS
    os_version     = `lsb_release -rs 2>/dev/null`.strip
    kernel_version = `uname -r 2>/dev/null`.strip
    msgs << "OS: Ubuntu #{os_version} / kernel #{kernel_version}"

    # Fetch CVE info in parallel
    cve_infos = valid.map { |id|
      Thread.new do
        raw = CveScanner::UbuntuCveScraperTool.new.execute(cve_id: id)
        [id, raw.start_with?("error=") ? {error: raw} : JSON.parse(raw, symbolize_names: true)]
      end
    }.each_with_object({}) { |t, h| h[t.value[0]] = t.value[1] }
    msgs += cve_infos.map { |id, info| "Fetched #{id}: priority=#{info[:priority] || "?"}" }

    # Broadcast informational messages in real-time before any LLM call.
    msgs.each { |m| ScanChannel.broadcast(scan_id, {type: "log", message: m}) } if scan_id

    state.merge(
      cve_ids: valid,
      os_version: os_version,
      kernel_version: kernel_version,
      cve_infos: cve_infos,
      messages: msgs
    )
  end

  def self.node_check_cve_data(state, scan_id: nil)
    pre_status = {}
    msgs = []
    state.cve_ids.each do |id|
      info = state.cve_infos[id] || {}
      if info[:error]
        pre_status[id] = "not_found"
        msgs << "#{id}: not found on Ubuntu security tracker — skipping checks."
      elsif info[:packages].nil? || info[:packages].empty?
        pre_status[id] = "no_packages"
        msgs << "#{id}: found on Ubuntu tracker but no affected packages listed — skipping checks."
      end
    end
    return state if pre_status.empty?
    msgs.each { |m| ScanChannel.broadcast(scan_id, {type: "log", message: m}) } if scan_id
    state.merge(vulnerability_status: state.vulnerability_status.merge(pre_status), messages: msgs)
  end

  def self.node_propose_checks(state, scan_id:)
    iteration = state.check_iteration + 1

    if iteration >= MAX_LOOP_ITERATIONS
      vuln_status = best_available_status(state)
      msg = "Check loop limit reached (#{MAX_LOOP_ITERATIONS}). Using best available assessment."
      ScanChannel.broadcast(scan_id, {type: "log", message: msg}) if scan_id
      return state.merge(
        check_decision: "done",
        check_iteration: iteration,
        vulnerability_status: vuln_status,
        proposed_checks: [],
        messages: [msg, *vuln_status.map { |id, s| "#{id}: #{s}" }]
      )
    end

    ScanChannel.broadcast(scan_id, {type: "agent_step", node: "propose_checks",
      message: "Round #{iteration}: asking analyst to review CVE info and propose checks..."}) if scan_id
    response = call_agent_json(CveScanner::CveAnalystAgent, build_check_context(state),
                               scan_id: scan_id, role: "CveAnalyst")

    if response["decision"] == "done"
      vuln_status = normalize_vuln_status(response["vulnerability_status"], state.cve_ids, scan_id: scan_id)
      reasoning   = response["reasoning"] || {}
      state.merge(
        check_decision: "done",
        check_iteration: iteration,
        vulnerability_status: vuln_status,
        vulnerability_reasoning: state.vulnerability_reasoning.merge(reasoning),
        proposed_checks: [],
        messages: ["Check round #{iteration}: agent determined status without additional commands."]
      )
    else
      proposed = Array(response["proposed_commands"])
      state.merge(
        check_decision: "need_more",
        check_iteration: iteration,
        proposed_checks: proposed,
        messages: ["Check round #{iteration}: proposed #{proposed.size} command(s)."]
      )
    end
  end

  def self.node_run_checks(state, scan_id: nil)
    results = state.approved_checks.map do |cmd|
      {cmd: cmd, output: CveScanner::CommandExecutorTool.new.execute(command: cmd)}
    end
    results.each { |r| ScanChannel.broadcast(scan_id, {type: "log", message: "Ran: #{r[:cmd]}"}) } if scan_id
    state.merge(
      check_history: results,
      messages: results.map { |r| "Ran: #{r[:cmd]}" }
    )
  end

  def self.node_evaluate_checks(state, scan_id:)
    # Guard: agent already decided "done" in :propose_checks with no commands
    return state if state.check_decision == "done" && state.approved_checks.empty?

    # User skipped — avoid a wasted LLM call; apply loop-limit guard
    if state.approved_checks.empty?
      if state.check_iteration >= MAX_LOOP_ITERATIONS
        vuln_status = best_available_status(state)
        msg = "Check loop limit reached (#{MAX_LOOP_ITERATIONS}). Using best available assessment."
        ScanChannel.broadcast(scan_id, {type: "log", message: msg}) if scan_id
        return state.merge(
          check_decision: "done",
          vulnerability_status: vuln_status,
          messages: [msg, *vuln_status.map { |id, s| "#{id}: #{s}" }]
        )
      end
      return state.merge(check_decision: "need_more")
    end

    ScanChannel.broadcast(scan_id, {type: "agent_step", node: "evaluate_checks",
      message: "Analyst evaluating command outputs..."}) if scan_id
    response = call_agent_json(CveScanner::CveAnalystAgent, build_check_context(state),
                               scan_id: scan_id, role: "CveAnalyst")

    if response["decision"] == "done" || state.check_iteration >= MAX_LOOP_ITERATIONS
      vuln_status = normalize_vuln_status(response["vulnerability_status"], state.cve_ids, scan_id: scan_id)
      reasoning   = response["reasoning"] || {}
      msg = state.check_iteration >= MAX_LOOP_ITERATIONS ?
              "Check loop limit reached (#{MAX_LOOP_ITERATIONS}). Using best available assessment." :
              "Check complete."
      state.merge(
        check_decision: "done",
        vulnerability_status: vuln_status,
        vulnerability_reasoning: state.vulnerability_reasoning.merge(reasoning),
        messages: [msg, *vuln_status.map { |id, s| "#{id}: #{s}" }]
      )
    else
      state.merge(check_decision: "need_more")
    end
  end

  def self.node_propose_remediation(state, scan_id:)
    iteration = state.remediation_iteration + 1

    if iteration >= MAX_LOOP_ITERATIONS
      msg = "Remediation loop limit reached (#{MAX_LOOP_ITERATIONS})."
      ScanChannel.broadcast(scan_id, {type: "log", message: msg}) if scan_id
      return state.merge(
        remediation_decision: "complete",
        remediation_iteration: iteration,
        proposed_remediations: [],
        messages: [msg]
      )
    end

    ScanChannel.broadcast(scan_id, {type: "agent_step", node: "propose_remediation",
      message: "Remediation round #{iteration}: asking advisor for next steps..."}) if scan_id
    response = call_agent_json(CveScanner::RemediationAdvisorAgent, build_remediation_context(state),
                               scan_id: scan_id, role: "RemediationAdvisor")

    if response["decision"] == "complete"
      state.merge(
        remediation_decision: "complete",
        remediation_iteration: iteration,
        proposed_remediations: [],
        messages: ["Remediation round #{iteration}: agent confirms complete."]
      )
    else
      proposed = Array(response["proposed_commands"])
      state.merge(
        remediation_decision: "need_more",
        remediation_iteration: iteration,
        proposed_remediations: proposed,
        messages: ["Remediation round #{iteration}: proposed #{proposed.size} command(s)."]
      )
    end
  end

  def self.node_run_remediation(state, scan_id: nil)
    results = state.approved_remediations.map do |cmd|
      {cmd: cmd, output: CveScanner::CommandExecutorTool.new.execute(command: cmd)}
    end
    results.each { |r| ScanChannel.broadcast(scan_id, {type: "log", message: "Ran: #{r[:cmd]}"}) } if scan_id
    state.merge(
      remediation_history: results,
      messages: results.map { |r| "Ran: #{r[:cmd]}" }
    )
  end

  def self.node_evaluate_remediation(state, scan_id:)
    # User skipped (approved nothing) — exit remediation loop immediately
    if state.approved_remediations.empty?
      return state.merge(remediation_decision: "complete")
    end

    ScanChannel.broadcast(scan_id, {type: "agent_step", node: "evaluate_remediation",
      message: "Advisor evaluating remediation results..."}) if scan_id
    response = call_agent_json(CveScanner::RemediationAdvisorAgent, build_remediation_context(state),
                               scan_id: scan_id, role: "RemediationAdvisor")

    if response["decision"] == "complete" || state.remediation_iteration >= MAX_LOOP_ITERATIONS
      msg = state.remediation_iteration >= MAX_LOOP_ITERATIONS ?
              "Remediation loop limit reached (#{MAX_LOOP_ITERATIONS})." :
              "Remediation complete."
      state.merge(remediation_decision: "complete", messages: [msg])
    else
      state.merge(remediation_decision: "need_more")
    end
  end

  # Keyword list that unambiguously signals the operator is done.
  DONE_KEYWORDS = %w[done exit quit finish end finished bye].freeze

  def self.node_handle_followup(state, scan_id:)
    request = state.followup_request.to_s.strip

    # Short-circuit: if the user explicitly says "done" (or a synonym) skip the
    # LLM call entirely. This avoids the LLM misclassifying the terminal keyword
    # as a question and returning "answered" instead of "done".
    if DONE_KEYWORDS.include?(request.downcase)
      farewell = "Session ended. Thank you for using CVE Scanner."
      # Use followup_answer (not chat_turn_done) so the farewell bubble is shown
      # in the UI and the JS handler can immediately hide the chat input bar.
      ScanChannel.broadcast(scan_id, {type: "followup_answer", role: "FollowupAgent",
        answer: farewell, decision: "done"}) if scan_id
      new_history = state.followup_history + [{question: request, answer: farewell}]
      return state.merge(
        followup_decision: "done",
        followup_request:  nil,
        followup_history:  new_history,
        messages:          ["Follow-up (done): #{request}"]
      )
    end

    ScanChannel.broadcast(scan_id, {type: "agent_step", node: "handle_followup",
      message: "Processing follow-up: #{request.slice(0, 120)}..."}) if scan_id

    prompt = build_followup_context(state, request)
    response = call_agent_json(CveScanner::FollowupAgent, prompt,
                               scan_id: scan_id, role: "FollowupAgent")

    decision = response["decision"].to_s.strip
    decision = "answered" unless %w[answered reinvestigate remediate report done].include?(decision)
    answer   = response["answer"].to_s.strip

    # Broadcast the answer so the UI shows it in the chat
    ScanChannel.broadcast(scan_id, {type: "followup_answer", answer: answer, decision: decision}) if scan_id

    new_history = state.followup_history + [{question: request, answer: answer}]

    updates = {
      followup_decision: decision,
      followup_request:  nil,  # clear so interrupt fires again on next turn
      followup_history:  new_history,
      messages:          ["Follow-up (#{decision}): #{request.slice(0, 80)}"]
    }

    # Reset scan state for a full re-investigation from scratch
    if decision == "reinvestigate"
      updates.merge!(
        check_iteration:         0,
        check_decision:          nil,
        proposed_checks:         [],
        approved_checks:         [],
        check_history:           [],
        vulnerability_status:    {},
        vulnerability_reasoning: {},
        remediation_iteration:   0,
        remediation_decision:    nil,
        proposed_remediations:   [],
        approved_remediations:   [],
        remediation_history:     []
      )
      ScanChannel.broadcast(scan_id, {type: "status", message: "Re-investigation requested. Restarting scan..."}) if scan_id
    end

    state.merge(updates)
  end

  def self.node_report(state, scan_id: nil)
    lines = ["=== CVE Scan Report ==="]
    state.vulnerability_status.each do |cve_id, status|
      info        = sym_keys(state.cve_infos[cve_id] || {})
      description = info[:description] || "no description available"
      pkgs        = info[:packages]
      pkg_summary = pkgs.is_a?(Hash) && pkgs.any? ? pkgs.keys.first(5).join(", ") : "n/a"
      reasoning   = state.vulnerability_reasoning[cve_id] || state.vulnerability_reasoning[cve_id.to_s]

      display = case status
                when "not_found"
                  "NOT FOUND — This CVE is not registered on the Ubuntu Security Tracker."
                when "no_packages"
                  "NO AFFECTED PACKAGES — #{description}"
                when "vulnerable"
                  remediated = state.remediation_history.map { |r| r.is_a?(Hash) ? (r[:cmd] || r["cmd"]) : nil }.compact
                  remediated.any? ? "REMEDIATED" : "VULNERABLE"
                else
                  status.upcase
                end

      lines << "#{cve_id}: #{display}"
      lines << "  Package(s): #{pkg_summary}" unless %w[not_found no_packages].include?(status)
      lines << "  Description: #{description}" unless status == "not_found"
      lines << "  Assessment: #{reasoning}"    if reasoning && !reasoning.empty?
    end
    lines << "---"
    lines << "Check rounds: #{state.check_iteration}"
    lines << "Remediation rounds: #{state.remediation_iteration}"

    # Broadcast structured report event so the UI can render the results table
    if scan_id
      cve_details = state.vulnerability_status.transform_keys(&:to_s).each_with_object({}) do |(cve_id, _), h|
        raw_info = state.cve_infos[cve_id] || state.cve_infos[cve_id.to_sym] || {}
        info = raw_info.is_a?(Hash) ? raw_info.transform_keys(&:to_s) : {}
        pkgs = info["packages"]
        pkg_names = pkgs.is_a?(Hash) ? pkgs.keys.first(5) : []
        h[cve_id] = {
          priority:    info["priority"]    || "unknown",
          description: info["description"] || "",
          packages:    pkg_names,
          reasoning:   (state.vulnerability_reasoning[cve_id] || state.vulnerability_reasoning[cve_id.to_sym] || "")
        }
      end
      ScanChannel.broadcast(scan_id, {
        type:                 "scan_report",
        vulnerability_status: state.vulnerability_status,
        check_iterations:     state.check_iteration,
        remediation_iterations: state.remediation_iteration,
        cve_details:          cve_details
      })
    end

    # Only append a single summary line to :messages so the full report text
    # does not accumulate in state and bloat the LLM context on repeat calls.
    summary = state.vulnerability_status.map { |id, s| "#{id}: #{s.upcase}" }.join(", ")
    state.merge(messages: ["Report generated. #{summary}"])
  end

  # ── Context builders ─────────────────────────────────────────────────────

  # Mock LLM responses for local UI testing (no real API calls).
  # Activate with: CVE_SCANNER_MOCK_LLM=1 bundle exec rails server -p 3020
  def self.mock_agent_response(agent_class, prompt, scan_id:, role:)
    cve_ids = prompt.scan(/CVE-\d{4}-\d{4,}/i).uniq
    response = case agent_class.name
               when /CveAnalystAgent/
                 vuln_status = cve_ids.each_with_object({}) { |id, h| h[id] = "vulnerable" }
                 reasoning   = cve_ids.each_with_object({}) { |id, h| h[id] = "Mock: package is vulnerable (fixed response)." }
                 {"decision" => "done", "vulnerability_status" => vuln_status, "reasoning" => reasoning}
               when /FollowupAgent/
                 {"decision" => "answered",
                  "answer" => "Mock answer: The affected package has a known vulnerability. No patch is currently available for Ubuntu 24.04."}
               when /RemediationAdvisorAgent/
                 {"decision" => "complete", "summary" => "Mock: Remediation complete."}
               else
                 {"decision" => "done"}
               end
    if scan_id
      ScanChannel.broadcast(scan_id, {type: "chat_turn_start", role: role,
        prompt_preview: "[MOCK] #{prompt.slice(0, 180)}"})
      ScanChannel.broadcast(scan_id, {type: "chat_turn_done", role: role, content: response.to_json})
    end
    response
  end

  # Normalise vulnerability_status keys returned by an LLM to always match the
  # known CVE IDs supplied by the operator. LLMs occasionally corrupt CVE-ID
  # tokens (e.g. "VEC-2023521-60" instead of "CVE-2023-52160"). Any CVE absent
  # from the raw response is set to "unknown", and a warning is broadcast so
  # the operator can see the problem in the pipeline log.
  def self.normalize_vuln_status(raw_status, cve_ids, scan_id: nil)
    raw = raw_status.is_a?(Hash) ? raw_status : {}
    mangled = raw.keys.reject { |k| k.match?(/\ACVE-\d{4}-\d{4,}\z/i) }
    missing = cve_ids.reject { |id| raw.key?(id) }
    if mangled.any? && missing.any?
      msg = "WARNING: LLM returned unrecognised key(s) [#{mangled.join(", ")}] — " \
            "expected [#{missing.join(", ")}]. Forcing to 'unknown'."
      ScanChannel.broadcast(scan_id, {type: "log", message: msg}) if scan_id
      Rails.logger.warn("[CveScanner] #{msg}")
    end
    cve_ids.each_with_object({}) { |id, h| h[id] = raw[id] || "unknown" }
  end

  # Returns the current vulnerability_status if non-empty, otherwise a hash
  # mapping every CVE ID to "unknown". Used as a safe fallback when loop
  # limits are reached.
  def self.best_available_status(state)
    return state.vulnerability_status if state.vulnerability_status.any?
    state.cve_ids.each_with_object({}) { |id, h| h[id] = "unknown" }
  end

  # Recursively normalize hash keys to symbols (JSON round-trip safety).
  # Maps Ubuntu version numbers to release codenames used by the Ubuntu security tracker.
  UBUNTU_SERIES = {
    "25.10" => "questing",
    "25.04" => "plucky",
    "24.10" => "oracular",
    "24.04" => "noble",
    "23.10" => "mantic",
    "23.04" => "lunar",
    "22.04" => "jammy",
    "21.10" => "impish",
    "21.04" => "hirsute",
    "20.04" => "focal",
    "18.04" => "bionic",
    "16.04" => "xenial",
    "14.04" => "trusty"
  }.freeze

  # Returns the Ubuntu release codename for a given version string (e.g. "24.04" -> "noble").
  def self.ubuntu_series_codename(os_version)
    version = os_version.to_s.split.first
    UBUNTU_SERIES.fetch(version, version.downcase)
  end

  def self.sym_keys(h)
    return {} unless h.is_a?(Hash)
    h.transform_keys(&:to_sym).transform_values { |v| v.is_a?(Hash) ? sym_keys(v) : v }
  end

  def self.build_check_context(state)
    lines = []
    # User notes from previous approval steps
    if state.user_notes.is_a?(Array) && state.user_notes.any?
      lines << "== Notes from operator =="
      state.user_notes.each { |n| lines << n }
      lines << "=========================="
      lines << ""
    end
    lines << "OS: Ubuntu #{state.os_version} / kernel #{state.kernel_version}"
    lines << ""
    lines << "CVE information (only CVEs with package data):"
    host_series = ubuntu_series_codename(state.os_version.to_s)
    checkable_ids = state.cve_ids.reject { |id| %w[not_found no_packages].include?(state.vulnerability_status[id]) }
    checkable_ids.each do |cve_id|
      raw_info = state.cve_infos[cve_id] || {}
      info = sym_keys(raw_info)
      # Restrict to packages that have an entry for the host's Ubuntu series to
      # avoid enumerating all 150+ kernel variants for linux CVEs.
      # sym_keys() converts all nested keys to symbols, so compare with symbol.
      host_series_sym = host_series.to_sym
      host_pkgs = info[:packages].is_a?(Hash) ? info[:packages].select do |_, sm|
        next false unless sm.is_a?(Hash)
        detail = sm[host_series_sym]
        # Skip packages that don't exist in this Ubuntu series.
        detail.is_a?(Hash) && detail[:status].to_s !~ /\ANot in release/i
      end : {}
      pkgs_label = host_pkgs.any? ? host_pkgs.keys.join(", ") : "?"
      lines << "  #{cve_id}: priority=#{info[:priority] || "?"}, packages=#{pkgs_label}"
      lines << "    description: #{info[:description]&.slice(0, 300)}"

      # Ubuntu security team notes — often contain critical triage context
      if info[:notes].is_a?(Array) && info[:notes].any?
        lines << "    notes:"
        info[:notes].first(5).each { |n| lines << "      #{n.slice(0, 300)}" }
      end

      # References — NVD/NIST/distro advisories useful for AI triage
      if info[:references].is_a?(Array) && info[:references].any?
        lines << "    references: #{info[:references].first(5).join(", ")}"
      end

      # Per-release package status for the host's Ubuntu series only.
      host_pkgs.each do |pkg_name, series_map|
        detail = series_map[host_series_sym]
        next unless detail.is_a?(Hash)
        d = detail.transform_keys(&:to_sym)
        lines << "    package #{pkg_name} [#{host_series}]: status=#{d[:status]}, fix=#{d[:fix_version] || "n/a"}"
      end
    end
    lines << ""
    if state.check_history.any?
      lines << "Commands already executed and their outputs:"
      state.check_history.each do |raw_entry|
        entry = raw_entry.is_a?(Hash) ? raw_entry.transform_keys(&:to_sym) : {}
        lines << "  CMD: #{entry[:cmd]}"
        lines << "  OUT: #{entry[:output]&.slice(0, 500)}"
        lines << ""
      end
    else
      lines << "No commands have been executed yet."
    end
    lines.join("\n")
  end

  def self.build_followup_context(state, request)
    lines = []
    # Skip pipeline log messages (check outputs, report lines) — the structured
    # sections below give the LLM everything it needs without repetition.
    lines << "== Vulnerability Status =="
    state.vulnerability_status.each do |cve_id, status|
      reasoning = state.vulnerability_reasoning[cve_id] || state.vulnerability_reasoning[cve_id.to_s]
      lines << "  #{cve_id}: #{status}#{reasoning ? " — #{reasoning.slice(0, 200)}" : ""}"
    end
    # Include CVE notes and reference URLs so the agent can fetch them proactively
    cve_infos = state.cve_infos || {}
    if cve_infos.any?
      lines << ""
      lines << "== CVE Notes & Reference URLs =="
      cve_infos.each do |cve_id, info|
        info = info.is_a?(Hash) ? info.transform_keys(&:to_s) : {}
        if (notes = Array(info["notes"]).reject(&:empty?)).any?
          lines << "#{cve_id} notes:"
          notes.each { |n| lines << "  - #{n}" }
        end
        if (refs = Array(info["references"]).reject(&:empty?)).any?
          lines << "#{cve_id} references: #{refs.join(", ")}"
        end
      end
    end
    if state.followup_history.any?
      lines << ""
      lines << "== Previous Q&A =="
      state.followup_history.each do |turn|
        t = turn.is_a?(Hash) ? turn.transform_keys(&:to_sym) : {}
        lines << "Q: #{t[:question]}"
        lines << "A: #{t[:answer]}"
        lines << ""
      end
    end
    lines << "== Operator's current message =="
    lines << request
    lines.join("\n")
  end

  def self.build_remediation_context(state)
    lines = []
    # User notes from previous approval steps
    if state.user_notes.is_a?(Array) && state.user_notes.any?
      lines << "== Notes from operator =="
      state.user_notes.each { |n| lines << n }
      lines << "=========================="
      lines << ""
    end
    lines << "Vulnerable CVEs:"
    state.vulnerability_status.select { |_, s| s == "vulnerable" }.each do |cve_id, _|
      info = sym_keys(state.cve_infos[cve_id] || state.cve_infos[cve_id.to_s] || {})
      pkgs = info[:packages].is_a?(Hash) ? info[:packages].keys.join(", ") : "?"
      lines << "  #{cve_id}: packages=#{pkgs}"
    end
    lines << ""
    if state.remediation_history.any?
      lines << "Remediation commands already executed:"
      state.remediation_history.each do |raw_entry|
        entry = raw_entry.is_a?(Hash) ? raw_entry.transform_keys(&:to_sym) : {}
        lines << "  CMD: #{entry[:cmd]}"
        lines << "  OUT: #{entry[:output]&.slice(0, 500)}"
        lines << ""
      end
    else
      lines << "No remediation commands have been executed yet."
    end
    lines.join("\n")
  end
end
