# frozen_string_literal: true

require "json"

module CveScanner
  MAX_LOOP_ITERATIONS = 10

  def self.completed_task(value, name: "cve-scanner-completed")
    Phronomy::TaskResult.completed(value, name: name)
  end

  def self.failed_task(error, name: "cve-scanner-failed")
    Phronomy::TaskResult.failed(error, name: name)
  end

  # Compatibility/injection seam used by this application and its tests.
  #
  # The default implementation returns a Phronomy completion handle. Tests may
  # stub this method with an already-parsed Hash; call_agent_json_async normalizes
  # either form without changing the Workflow control plane.
  def self.call_agent_json(agent_class, prompt, agents:, notifications: nil, role: agent_class.name.split("::").last)
    start_agent_json_operation(
      agent_class,
      prompt,
      agents: agents,
      notifications: notifications,
      role: role
    )
  end

  # Starts an Agent lifecycle directly through Phronomy's EventLoop/FSMSession
  # control plane. No OffloadPool worker is occupied merely waiting for
  # the child Agent to finish.
  def self.call_agent_json_async(agent_class, prompt, agents:, notifications: nil, role: agent_class.name.split("::").last)
    operation = call_agent_json(
      agent_class,
      prompt,
      agents: agents,
      notifications: notifications,
      role: role
    )

    return operation if operation.respond_to?(:on_complete)

    Phronomy::TaskResult.completed(operation, name: "cve-scanner-stub-#{role}")
  rescue => error
    Phronomy::TaskResult.failed(error, name: "cve-scanner-agent-#{role}")
  end

  def self.start_agent_json_operation(agent_class, prompt, agents:, notifications:, role:)
    if ENV["CVE_SCANNER_MOCK_LLM"].present?
      return Phronomy::TaskResult.completed(
        mock_agent_response(agent_class, prompt, notifications: notifications, role: role),
        name: "cve-scanner-mock-#{role}"
      )
    end

    if notifications
      notifications.publish(type: "chat_turn_start", role: role, prompt_preview: prompt.slice(0, 200))
    end

    materialization = agents.create_async(agent_class,
      on_event: ->(event) {
        case event.type
        when :token
          token = event.payload[:content].to_s
          notifications.publish(type: "llm_token", role: role, token: token) if notifications
        when :tool_call
          tool_call = event.payload[:tool_call]
          tool_name = tool_call.respond_to?(:name) ? tool_call.name.to_s : "tool"
          args = tool_call.respond_to?(:arguments) ? tool_call.arguments.inspect.slice(0, 120) : ""
          notifications.publish(type: "log", subtype: "tool_call", message: "#{role} -> calling #{tool_name}: #{args}") if notifications
        when :tool_result
          tool_name = event.payload.fetch(:tool_name).to_s
          result_text = event.payload[:tool_result].to_s
          notifications.publish(type: "log", subtype: "tool_result", message: "#{role} <- #{tool_name} result (#{result_text.length} chars)") if notifications
        end
      }
    )
    source = materialization.flat_map do |agent|
      agent.stream_async(prompt, output_schema: agent_class::OUTPUT_SCHEMA, schema_delivery: :none)
    end

    source.map do |result|
      # Only a validated final value can publish completion. Tokens are provisional.
      parsed = result.fetch(:output)
      notifications.publish(type: "chat_turn_done", role: role, content: parsed.to_json) if notifications
      parsed
    end
  rescue => error
    Phronomy::TaskResult.failed(error, name: "cve-scanner-agent-#{role}")
  end

  def self.build_graph(agents:, notifications: nil)
    Phronomy::Workflow.define(CveScanner::ScanState) do
      initial :gather_scan_info

      task_state :gather_scan_info,
        start: ->(snapshot) {
          Phronomy::Blocking.call_async do
            CveScanner.node_gather_scan_info(snapshot, notifications: notifications)
          end
        },
        apply: ->(_state, updated) { updated }

      state :check_cve_data, action: lambda { |state|
        CveScanner.node_check_cve_data(state, notifications: notifications)
      }

      task_state :propose_checks,
        start: ->(snapshot) {
          CveScanner.node_propose_checks_async(snapshot, agents: agents, notifications: notifications)
        },
        apply: ->(_state, updated) { updated }

      task_state :run_checks,
        start: ->(snapshot) {
          Phronomy::Blocking.call_async do
            CveScanner.node_run_checks(snapshot, notifications: notifications)
          end
        },
        apply: ->(_state, updated) { updated }

      task_state :evaluate_checks,
        start: ->(snapshot) {
          CveScanner.node_evaluate_checks_async(snapshot, agents: agents, notifications: notifications)
        },
        apply: ->(_state, updated) { updated }

      task_state :propose_remediation,
        start: ->(snapshot) {
          CveScanner.node_propose_remediation_async(snapshot, agents: agents, notifications: notifications)
        },
        apply: ->(_state, updated) { updated }

      task_state :run_remediation,
        start: ->(snapshot) {
          Phronomy::Blocking.call_async do
            CveScanner.node_run_remediation(snapshot, notifications: notifications)
          end
        },
        apply: ->(_state, updated) { updated }

      task_state :evaluate_remediation,
        start: ->(snapshot) {
          CveScanner.node_evaluate_remediation_async(snapshot, agents: agents, notifications: notifications)
        },
        apply: ->(_state, updated) { updated }

      state :report, action: lambda { |state|
        CveScanner.node_report(state, notifications: notifications)
      }

      task_state :handle_followup,
        start: ->(snapshot) {
          CveScanner.node_handle_followup_async(snapshot, agents: agents, notifications: notifications)
        },
        apply: ->(_state, updated) { updated }

      wait_state :awaiting_check_approval
      wait_state :awaiting_remediation_approval
      wait_state :awaiting_followup

      transition from: :gather_scan_info, to: :check_cve_data

      transition from: :check_cve_data,
        guard: ->(state) {
          checkable = state.cve_ids.reject do |id|
            %w[not_found no_packages].include?(state.vulnerability_status[id])
          end
          checkable.empty?
        },
        to: :report
      transition from: :check_cve_data, to: :propose_checks

      transition from: :propose_checks,
        guard: ->(state) { state.check_decision == "need_more" },
        to: :awaiting_check_approval
      transition from: :propose_checks, to: :report

      transition from: :awaiting_check_approval, on: :approve_checks, to: :run_checks
      transition from: :run_checks, to: :evaluate_checks
      transition from: :evaluate_checks,
        guard: ->(state) { state.check_decision == "need_more" },
        to: :propose_checks
      transition from: :evaluate_checks, to: :report

      transition from: :propose_remediation,
        guard: ->(state) { state.remediation_decision == "need_more" },
        to: :awaiting_remediation_approval
      transition from: :propose_remediation, to: :report

      transition from: :awaiting_remediation_approval, on: :approve_remediation, to: :run_remediation
      transition from: :run_remediation, to: :evaluate_remediation
      transition from: :evaluate_remediation,
        guard: ->(state) { state.remediation_decision == "need_more" },
        to: :propose_remediation
      transition from: :evaluate_remediation, to: :report

      transition from: :report, to: :awaiting_followup
      transition from: :awaiting_followup, on: :submit_followup, to: :handle_followup

      transition from: :handle_followup,
        guard: ->(state) { state.followup_decision == "answered" },
        to: :awaiting_followup
      transition from: :handle_followup,
        guard: ->(state) { state.followup_decision == "reinvestigate" },
        to: :gather_scan_info
      transition from: :handle_followup,
        guard: ->(state) { state.followup_decision == "remediate" },
        to: :propose_remediation
      transition from: :handle_followup,
        guard: ->(state) { state.followup_decision == "report" },
        to: :report
      transition from: :handle_followup, to: :__finish__
    end

  end

  # Runs only inside Phronomy::Blocking.call_async. The scraper and shell commands are
  # blocking application I/O; they stay inside the bounded blocking pool.
  def self.node_gather_scan_info(state, notifications: nil)
    valid = state.cve_ids.select { |id| id.match?(/\ACVE-\d{4}-\d{4,}\z/i) }
    invalid = state.cve_ids - valid
    messages = valid.any? ? [] : ["ERROR: No valid CVE IDs provided."]
    messages << "Skipping invalid IDs: #{invalid.join(", ")}" if invalid.any?

    os_version = `lsb_release -rs 2>/dev/null`.strip
    kernel_version = `uname -r 2>/dev/null`.strip
    messages << "OS: Ubuntu #{os_version} / kernel #{kernel_version}"

    cve_infos = valid.each_with_object({}) do |id, hash|
      raw = CveScanner::UbuntuCveScraperTool.new.execute(cve_id: id)
      hash[id] = raw.start_with?("error=") ? {error: raw} : JSON.parse(raw, symbolize_names: true)
    end

    messages += cve_infos.map { |id, info| "Fetched #{id}: priority=#{info[:priority] || "?"}" }
    messages.each { |message| notifications.publish(type: "log", message: message) } if notifications

    state.merge(
      cve_ids: valid,
      os_version: os_version,
      kernel_version: kernel_version,
      cve_infos: cve_infos,
      messages: messages
    )
  end

  def self.node_check_cve_data(state, notifications: nil)
    pre_status = {}
    messages = []
    state.cve_ids.each do |id|
      info = state.cve_infos[id] || {}
      if info[:error]
        pre_status[id] = "not_found"
        messages << "#{id}: not found on Ubuntu security tracker — skipping checks."
      elsif info[:packages].nil? || info[:packages].empty?
        pre_status[id] = "no_packages"
        messages << "#{id}: found on Ubuntu tracker but no affected packages listed — skipping checks."
      end
    end
    return state if pre_status.empty?

    messages.each { |message| notifications.publish(type: "log", message: message) } if notifications
    state.merge(vulnerability_status: state.vulnerability_status.merge(pre_status), messages: messages)
  end

  def self.node_propose_checks_async(state, agents:, notifications:)
    iteration = state.check_iteration + 1

    if iteration >= MAX_LOOP_ITERATIONS
      vuln_status = best_available_status(state)
      message = "Check loop limit reached (#{MAX_LOOP_ITERATIONS}). Using best available assessment."
      notifications.publish(type: "log", message: message) if notifications
      return Phronomy::TaskResult.completed(
        state.merge(
          check_decision: "done",
          check_iteration: iteration,
          vulnerability_status: vuln_status,
          proposed_checks: [],
          messages: [message, *vuln_status.map { |id, status| "#{id}: #{status}" }]
        ),
        name: "cve-scanner-propose-checks-limit"
      )
    end

    notifications.publish(type: "agent_step", node: "propose_checks", message: "Round #{iteration}: asking analyst to review CVE info and propose checks...") if notifications

    call_agent_json_async(
      CveScanner::CveAnalystAgent,
      build_check_context(state),
      agents: agents,
      notifications: notifications,
      role: "CveAnalyst"
    ).map do |response|
      if response["decision"] == "done"
        vuln_status = normalize_vuln_status(response["vulnerability_status"], state.cve_ids, notifications: notifications)
        reasoning = response["reasoning"] || {}
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
  end

  def self.node_propose_checks(state, agents:, notifications:)
    node_propose_checks_async(state, agents: agents, notifications: notifications).wait_result
  end

  # Runs only inside Phronomy::Blocking.call_async.
  def self.node_run_checks(state, notifications: nil)
    results = state.approved_checks.map do |command|
      {cmd: command, output: CveScanner::CommandExecutorTool.new.execute(command: command)}
    end
    results.each { |result| notifications.publish(type: "log", message: "Ran: #{result[:cmd]}") } if notifications
    state.merge(
      check_history: results,
      messages: results.map { |result| "Ran: #{result[:cmd]}" }
    )
  end

  def self.node_evaluate_checks_async(state, agents:, notifications:)
    return Phronomy::TaskResult.completed(state, name: "cve-scanner-evaluate-noop") if state.check_decision == "done" && state.approved_checks.empty?

    if state.approved_checks.empty?
      if state.check_iteration >= MAX_LOOP_ITERATIONS
        vuln_status = best_available_status(state)
        message = "Check loop limit reached (#{MAX_LOOP_ITERATIONS}). Using best available assessment."
        notifications.publish(type: "log", message: message) if notifications
        return Phronomy::TaskResult.completed(
          state.merge(
            check_decision: "done",
            vulnerability_status: vuln_status,
            messages: [message, *vuln_status.map { |id, status| "#{id}: #{status}" }]
          ),
          name: "cve-scanner-evaluate-limit"
        )
      end
      return Phronomy::TaskResult.completed(state.merge(check_decision: "need_more"), name: "cve-scanner-evaluate-empty")
    end

    notifications.publish(type: "agent_step", node: "evaluate_checks", message: "Analyst evaluating command outputs...") if notifications

    call_agent_json_async(
      CveScanner::CveAnalystAgent,
      build_check_context(state),
      agents: agents,
      notifications: notifications,
      role: "CveAnalyst"
    ).map do |response|
      if response["decision"] == "done" || state.check_iteration >= MAX_LOOP_ITERATIONS
        vuln_status = normalize_vuln_status(response["vulnerability_status"], state.cve_ids, notifications: notifications)
        reasoning = response["reasoning"] || {}
        message = state.check_iteration >= MAX_LOOP_ITERATIONS ?
          "Check loop limit reached (#{MAX_LOOP_ITERATIONS}). Using best available assessment." : "Check complete."
        state.merge(
          check_decision: "done",
          vulnerability_status: vuln_status,
          vulnerability_reasoning: state.vulnerability_reasoning.merge(reasoning),
          messages: [message, *vuln_status.map { |id, status| "#{id}: #{status}" }]
        )
      else
        state.merge(check_decision: "need_more")
      end
    end
  end

  def self.node_evaluate_checks(state, agents:, notifications:)
    node_evaluate_checks_async(state, agents: agents, notifications: notifications).wait_result
  end

  def self.node_propose_remediation_async(state, agents:, notifications:)
    iteration = state.remediation_iteration + 1

    if iteration >= MAX_LOOP_ITERATIONS
      message = "Remediation loop limit reached (#{MAX_LOOP_ITERATIONS})."
      notifications.publish(type: "log", message: message) if notifications
      return Phronomy::TaskResult.completed(
        state.merge(
          remediation_decision: "complete",
          remediation_iteration: iteration,
          proposed_remediations: [],
          messages: [message]
        ),
        name: "cve-scanner-remediation-limit"
      )
    end

    notifications.publish(type: "agent_step", node: "propose_remediation", message: "Remediation round #{iteration}: asking advisor for next steps...") if notifications

    call_agent_json_async(
      CveScanner::RemediationAdvisorAgent,
      build_remediation_context(state),
      agents: agents,
      notifications: notifications,
      role: "RemediationAdvisor"
    ).map do |response|
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
  end

  def self.node_propose_remediation(state, agents:, notifications:)
    node_propose_remediation_async(state, agents: agents, notifications: notifications).wait_result
  end

  # Runs only inside Phronomy::Blocking.call_async.
  def self.node_run_remediation(state, notifications: nil)
    results = state.approved_remediations.map do |command|
      {cmd: command, output: CveScanner::CommandExecutorTool.new.execute(command: command)}
    end
    results.each { |result| notifications.publish(type: "log", message: "Ran: #{result[:cmd]}") } if notifications
    state.merge(
      remediation_history: results,
      messages: results.map { |result| "Ran: #{result[:cmd]}" }
    )
  end

  def self.node_evaluate_remediation_async(state, agents:, notifications:)
    return Phronomy::TaskResult.completed(state.merge(remediation_decision: "complete"), name: "cve-scanner-remediation-noop") if state.approved_remediations.empty?

    notifications.publish(type: "agent_step", node: "evaluate_remediation", message: "Advisor evaluating remediation results...") if notifications

    call_agent_json_async(
      CveScanner::RemediationAdvisorAgent,
      build_remediation_context(state),
      agents: agents,
      notifications: notifications,
      role: "RemediationAdvisor"
    ).map do |response|
      if response["decision"] == "complete" || state.remediation_iteration >= MAX_LOOP_ITERATIONS
        message = state.remediation_iteration >= MAX_LOOP_ITERATIONS ?
          "Remediation loop limit reached (#{MAX_LOOP_ITERATIONS})." : "Remediation complete."
        state.merge(remediation_decision: "complete", messages: [message])
      else
        state.merge(remediation_decision: "need_more")
      end
    end
  end

  def self.node_evaluate_remediation(state, agents:, notifications:)
    node_evaluate_remediation_async(state, agents: agents, notifications: notifications).wait_result
  end

  DONE_KEYWORDS = %w[done exit quit finish end finished bye].freeze

  def self.node_handle_followup_async(state, agents:, notifications:)
    request = state.followup_request.to_s.strip

    if DONE_KEYWORDS.include?(request.downcase)
      farewell = "Session ended. Thank you for using CVE Scanner."
      notifications.publish(type: "followup_answer", role: "FollowupAgent", answer: farewell, decision: "done") if notifications
      new_history = state.followup_history + [{question: request, answer: farewell}]
      return Phronomy::TaskResult.completed(
        state.merge(
          followup_decision: "done",
          followup_request: nil,
          followup_history: new_history,
          messages: ["Follow-up (done): #{request}"]
        ),
        name: "cve-scanner-followup-done"
      )
    end

    notifications.publish(type: "agent_step", node: "handle_followup", message: "Processing follow-up: #{request.slice(0, 120)}...") if notifications

    call_agent_json_async(
      CveScanner::FollowupAgent,
      build_followup_context(state, request),
      agents: agents,
      notifications: notifications,
      role: "FollowupAgent"
    ).map do |response|
      decision = response["decision"].to_s.strip
      decision = "answered" unless %w[answered reinvestigate remediate report done].include?(decision)
      answer = response["answer"].to_s.strip
      notifications.publish(type: "followup_answer", answer: answer, decision: decision) if notifications

      updates = {
        followup_decision: decision,
        followup_request: nil,
        followup_history: state.followup_history + [{question: request, answer: answer}],
        messages: ["Follow-up (#{decision}): #{request.slice(0, 80)}"]
      }

      if decision == "reinvestigate"
        updates.merge!(
          check_iteration: 0,
          check_decision: nil,
          proposed_checks: [],
          approved_checks: [],
          check_history: [],
          vulnerability_status: {},
          vulnerability_reasoning: {},
          remediation_iteration: 0,
          remediation_decision: nil,
          proposed_remediations: [],
          approved_remediations: [],
          remediation_history: []
        )
        notifications.publish(type: "status", message: "Re-investigation requested. Restarting scan...") if notifications
      end

      state.merge(updates)
    end
  end

  def self.node_handle_followup(state, agents:, notifications:)
    node_handle_followup_async(state, agents: agents, notifications: notifications).wait_result
  end

  def self.node_report(state, notifications: nil)
    if notifications
      cve_details = state.vulnerability_status.transform_keys(&:to_s).each_with_object({}) do |(cve_id, _), hash|
        raw_info = state.cve_infos[cve_id] || state.cve_infos[cve_id.to_sym] || {}
        info = raw_info.is_a?(Hash) ? raw_info.transform_keys(&:to_s) : {}
        packages = info["packages"]
        hash[cve_id] = {
          priority: info["priority"] || "unknown",
          description: info["description"] || "",
          packages: packages.is_a?(Hash) ? packages.keys.first(5) : [],
          reasoning: state.vulnerability_reasoning[cve_id] || state.vulnerability_reasoning[cve_id.to_sym] || ""
        }
      end
      notifications.publish(
          type: "scan_report",
          vulnerability_status: state.vulnerability_status,
          check_iterations: state.check_iteration,
          remediation_iterations: state.remediation_iteration,
          cve_details: cve_details
        )
    end

    summary = state.vulnerability_status.map { |id, status| "#{id}: #{status.upcase}" }.join(", ")
    state.merge(messages: ["Report generated. #{summary}"])
  end

  def self.mock_agent_response(agent_class, prompt, notifications:, role:)
    cve_ids = prompt.scan(/CVE-\d{4}-\d{4,}/i).uniq
    response = case agent_class.name
    when /CveAnalystAgent/
      vuln_status = cve_ids.each_with_object({}) { |id, hash| hash[id] = "vulnerable" }
      reasoning = cve_ids.each_with_object({}) { |id, hash| hash[id] = "Mock: package is vulnerable (fixed response)." }
      {"decision" => "done", "vulnerability_status" => vuln_status, "reasoning" => reasoning}
    when /FollowupAgent/
      {"decision" => "answered", "answer" => "Mock answer: The affected package has a known vulnerability."}
    when /RemediationAdvisorAgent/
      {"decision" => "complete", "summary" => "Mock: Remediation complete."}
    else
      {"decision" => "done"}
    end

    if notifications
      notifications.publish(type: "chat_turn_start", role: role, prompt_preview: "[MOCK] #{prompt.slice(0, 180)}")
      notifications.publish(type: "chat_turn_done", role: role, content: response.to_json)
    end
    response
  end

  def self.normalize_vuln_status(raw_status, cve_ids, notifications: nil)
    raw = raw_status.is_a?(Hash) ? raw_status : {}
    mangled = raw.keys.reject { |key| key.match?(/\ACVE-\d{4}-\d{4,}\z/i) }
    missing = cve_ids.reject { |id| raw.key?(id) }
    if mangled.any? && missing.any?
      message = "WARNING: LLM returned unrecognised key(s) [#{mangled.join(", ")}] — expected [#{missing.join(", ")}]. Forcing to 'unknown'."
      notifications.publish(type: "log", message: message) if notifications
      Rails.logger.warn("[CveScanner] #{message}")
    end
    cve_ids.each_with_object({}) { |id, hash| hash[id] = raw[id] || "unknown" }
  end

  def self.best_available_status(state)
    return state.vulnerability_status if state.vulnerability_status.any?
    state.cve_ids.each_with_object({}) { |id, hash| hash[id] = "unknown" }
  end

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

  def self.ubuntu_series_codename(os_version)
    version = os_version.to_s.split.first
    UBUNTU_SERIES.fetch(version, version.downcase)
  end

  def self.sym_keys(hash)
    return {} unless hash.is_a?(Hash)
    hash.transform_keys(&:to_sym).transform_values { |value| value.is_a?(Hash) ? sym_keys(value) : value }
  end

  def self.build_check_context(state)
    lines = []
    if state.user_notes.is_a?(Array) && state.user_notes.any?
      lines << "== Notes from operator =="
      state.user_notes.each { |note| lines << note }
      lines << "=========================="
      lines << ""
    end
    lines << "OS: Ubuntu #{state.os_version} / kernel #{state.kernel_version}"
    lines << ""
    lines << "CVE information (only CVEs with package data):"
    host_series = ubuntu_series_codename(state.os_version.to_s)
    host_series_sym = host_series.to_sym
    checkable_ids = state.cve_ids.reject { |id| %w[not_found no_packages].include?(state.vulnerability_status[id]) }

    checkable_ids.each do |cve_id|
      info = sym_keys(state.cve_infos[cve_id] || {})
      host_packages = if info[:packages].is_a?(Hash)
        info[:packages].select do |_, series_map|
          next false unless series_map.is_a?(Hash)
          detail = series_map[host_series_sym]
          detail.is_a?(Hash) && detail[:status].to_s !~ /\ANot in release/i
        end
      else
        {}
      end
      lines << "  #{cve_id}: priority=#{info[:priority] || "?"}, packages=#{host_packages.any? ? host_packages.keys.join(", ") : "?"}"
      lines << "    description: #{info[:description]&.slice(0, 300)}"
      if info[:notes].is_a?(Array) && info[:notes].any?
        lines << "    notes:"
        info[:notes].first(5).each { |note| lines << "      #{note.slice(0, 300)}" }
      end
      if info[:references].is_a?(Array) && info[:references].any?
        lines << "    references: #{info[:references].first(5).join(", ")}"
      end
      host_packages.each do |package_name, series_map|
        detail = series_map[host_series_sym]
        next unless detail.is_a?(Hash)
        detail = detail.transform_keys(&:to_sym)
        lines << "    package #{package_name} [#{host_series}]: status=#{detail[:status]}, fix=#{detail[:fix_version] || "n/a"}"
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
    lines = ["== Vulnerability Status =="]
    state.vulnerability_status.each do |cve_id, status|
      reasoning = state.vulnerability_reasoning[cve_id] || state.vulnerability_reasoning[cve_id.to_s]
      lines << "  #{cve_id}: #{status}#{reasoning ? " — #{reasoning.slice(0, 200)}" : ""}"
    end

    cve_infos = state.cve_infos || {}
    if cve_infos.any?
      lines << ""
      lines << "== CVE Notes & Reference URLs =="
      cve_infos.each do |cve_id, info|
        info = info.is_a?(Hash) ? info.transform_keys(&:to_s) : {}
        notes = Array(info["notes"]).reject(&:empty?)
        references = Array(info["references"]).reject(&:empty?)
        if notes.any?
          lines << "#{cve_id} notes:"
          notes.each { |note| lines << "  - #{note}" }
        end
        lines << "#{cve_id} references: #{references.join(", ")}" if references.any?
      end
    end

    if state.followup_history.any?
      lines << ""
      lines << "== Previous Q&A =="
      state.followup_history.each do |turn|
        turn = turn.is_a?(Hash) ? turn.transform_keys(&:to_sym) : {}
        lines << "Q: #{turn[:question]}"
        lines << "A: #{turn[:answer]}"
        lines << ""
      end
    end

    lines << "== Operator's current message =="
    lines << request
    lines.join("\n")
  end

  def self.build_remediation_context(state)
    lines = []
    if state.user_notes.is_a?(Array) && state.user_notes.any?
      lines << "== Notes from operator =="
      state.user_notes.each { |note| lines << note }
      lines << "=========================="
      lines << ""
    end
    lines << "Vulnerable CVEs:"
    state.vulnerability_status.select { |_, status| status == "vulnerable" }.each do |cve_id, _|
      info = sym_keys(state.cve_infos[cve_id] || state.cve_infos[cve_id.to_s] || {})
      packages = info[:packages].is_a?(Hash) ? info[:packages].keys.join(", ") : "?"
      lines << "  #{cve_id}: packages=#{packages}"
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
