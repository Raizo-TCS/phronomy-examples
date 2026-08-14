# frozen_string_literal: true

require "json"

module CveScanner
  MAX_LOOP_ITERATIONS = 10

  def self.completed_task(value, name: "cve-scanner-completed")
    Phronomy::Task.deferred(name: name).tap { |task| task.complete(value) }
  end

  def self.failed_task(error, name: "cve-scanner-failed")
    Phronomy::Task.deferred(name: name).tap { |task| task.fail(error) }
  end

  # Compatibility/injection seam used by this application and its tests.
  #
  # The default implementation returns a Phronomy completion handle. Tests may
  # stub this method with an already-parsed Hash; call_agent_json_async normalizes
  # either form without changing the Workflow control plane.
  def self.call_agent_json(agent_class, prompt, scan_id: nil, role: agent_class.name.split("::").last)
    start_agent_json_operation(
      agent_class,
      prompt,
      scan_id: scan_id,
      role: role
    )
  end

  # Starts an Agent lifecycle directly through Phronomy's EventLoop/FSMSession
  # control plane. No OffloadPool worker is occupied merely waiting for
  # the child Agent to finish.
  def self.call_agent_json_async(agent_class, prompt, scan_id: nil, role: agent_class.name.split("::").last)
    operation = call_agent_json(
      agent_class,
      prompt,
      scan_id: scan_id,
      role: role
    )

    return operation if operation.respond_to?(:on_complete)

    completed_task(operation, name: "cve-scanner-stub-#{role}")
  rescue => error
    failed_task(error, name: "cve-scanner-agent-#{role}")
  end

  def self.start_agent_json_operation(agent_class, prompt, scan_id:, role:)
    if ENV["CVE_SCANNER_MOCK_LLM"].present?
      return completed_task(
        mock_agent_response(agent_class, prompt, scan_id: scan_id, role: role),
        name: "cve-scanner-mock-#{role}"
      )
    end

    agent = agent_class.new
    accumulated = +""
    last_tool_name = +"unknown"

    if scan_id
      ScanChannel.broadcast(
        scan_id,
        {type: "chat_turn_start", role: role, prompt_preview: prompt.slice(0, 200)}
      )
    end

    source = agent.stream_async(prompt) do |event|
      case event.type
      when :token
        token = event.payload[:content].to_s
        accumulated << token
        ScanChannel.broadcast(scan_id, {type: "llm_token", role: role, token: token}) if scan_id
      when :tool_call
        tool_call = event.payload[:tool_call]
        last_tool_name.replace(tool_call.respond_to?(:name) ? tool_call.name.to_s : "tool")
        args = tool_call.respond_to?(:arguments) ? tool_call.arguments.inspect.slice(0, 120) : ""
        ScanChannel.broadcast(
          scan_id,
          {type: "log", subtype: "tool_call", message: "#{role} -> calling #{last_tool_name}: #{args}"}
        ) if scan_id
      when :tool_result
        result_text = event.payload[:tool_result].to_s
        ScanChannel.broadcast(
          scan_id,
          {type: "log", subtype: "tool_result", message: "#{role} <- #{last_tool_name} result (#{result_text.length} chars)"}
        ) if scan_id
      end
    end

    source.map do |result|
      parse_agent_json_result(result, accumulated, scan_id: scan_id, role: role)
    end
  rescue => error
    failed_task(error, name: "cve-scanner-agent-#{role}")
  end

  def self.parse_agent_json_result(result, accumulated, scan_id:, role:)
    raw = result&.dig(:output).to_s.strip
    raw = accumulated.strip if raw.empty?
    raw = raw.gsub(/\A```(?:json)?\s*/i, "").gsub(/\s*```\z/, "").strip

    parsed = begin
      JSON.parse(raw)
    rescue JSON::ParserError
      match = raw.match(/\{.*\}/m)
      if match
        candidate = match[0]
        repaired = nil
        (0..5).each do |count|
          begin
            repaired = JSON.parse(candidate + ("}" * count))
            break
          rescue JSON::ParserError
            next
          end
        end
        repaired
      end
    end

    if parsed
      ScanChannel.broadcast(scan_id, {type: "chat_turn_done", role: role, content: parsed.to_json}) if scan_id
      parsed
    else
      ScanChannel.broadcast(scan_id, {type: "chat_turn_done", role: role, content: accumulated}) if scan_id
      {"decision" => "need_more", "proposed_commands" => [], "error" => "json_parse_failed"}
    end
  end

  def self.signal_node_result(workflow, thread_id:, event:, value:, error:)
    payload = error ? {error: error} : {state: value}
    workflow.signal(thread_id: thread_id, event: event, payload: payload)
  end

  # For logical asynchronous work already represented by a Phronomy completion
  # handle (Agent lifecycle, FanOut, another Workflow, ...).
  def self.start_task_node(workflow, state, event:, &operation_builder)
    snapshot = state.merge({})
    thread_id = state.thread_id
    operation = operation_builder.call(snapshot)

    unless operation.respond_to?(:on_complete)
      raise ArgumentError, "task node must return a completion handle"
    end

    operation.on_complete do |value, error|
      signal_node_result(
        workflow,
        thread_id: thread_id,
        event: event,
        value: value,
        error: error
      )
    end

    state
  rescue => error
    workflow.signal(thread_id: state.thread_id, event: event, payload: {error: error})
    state
  end

  # For genuinely blocking application operations such as shell commands and
  # the synchronous Ubuntu CVE scraper. The worker belongs to Phronomy's bounded
  # OffloadPool; the Workflow EventLoop never waits for it.
  def self.start_blocking_node(workflow, state, event:, &operation)
    snapshot = state.merge({})
    thread_id = state.thread_id
    pending = Phronomy::Runtime.instance.offload.submit do
      operation.call(snapshot)
    end

    pending.on_complete do |value, error|
      signal_node_result(
        workflow,
        thread_id: thread_id,
        event: event,
        value: value,
        error: error
      )
    end

    state
  rescue => error
    workflow.signal(thread_id: state.thread_id, event: event, payload: {error: error})
    state
  end

  def self.async_event_state(event)
    payload = event.payload || {}
    raise payload[:error] if payload[:error]
    payload.fetch(:state)
  end

  def self.build_graph(scan_id: nil)
    workflow = nil

    workflow = Phronomy::Workflow.define(CveScanner::ScanState) do
      initial :gather_scan_info

      state :gather_scan_info
      entry :gather_scan_info, lambda { |state|
        CveScanner.start_blocking_node(workflow, state, event: :gather_scan_info_done) do |snapshot|
          CveScanner.node_gather_scan_info(snapshot, scan_id: scan_id)
        end
      }

      state :check_cve_data, action: lambda { |state|
        CveScanner.node_check_cve_data(state, scan_id: scan_id)
      }

      state :propose_checks
      entry :propose_checks, lambda { |state|
        CveScanner.start_task_node(workflow, state, event: :propose_checks_done) do |snapshot|
          CveScanner.node_propose_checks_async(snapshot, scan_id: scan_id)
        end
      }

      state :run_checks
      entry :run_checks, lambda { |state|
        CveScanner.start_blocking_node(workflow, state, event: :run_checks_done) do |snapshot|
          CveScanner.node_run_checks(snapshot, scan_id: scan_id)
        end
      }

      state :evaluate_checks
      entry :evaluate_checks, lambda { |state|
        CveScanner.start_task_node(workflow, state, event: :evaluate_checks_done) do |snapshot|
          CveScanner.node_evaluate_checks_async(snapshot, scan_id: scan_id)
        end
      }

      state :propose_remediation
      entry :propose_remediation, lambda { |state|
        CveScanner.start_task_node(workflow, state, event: :propose_remediation_done) do |snapshot|
          CveScanner.node_propose_remediation_async(snapshot, scan_id: scan_id)
        end
      }

      state :run_remediation
      entry :run_remediation, lambda { |state|
        CveScanner.start_blocking_node(workflow, state, event: :run_remediation_done) do |snapshot|
          CveScanner.node_run_remediation(snapshot, scan_id: scan_id)
        end
      }

      state :evaluate_remediation
      entry :evaluate_remediation, lambda { |state|
        CveScanner.start_task_node(workflow, state, event: :evaluate_remediation_done) do |snapshot|
          CveScanner.node_evaluate_remediation_async(snapshot, scan_id: scan_id)
        end
      }

      state :report, action: lambda { |state|
        CveScanner.node_report(state, scan_id: scan_id)
      }

      state :handle_followup
      entry :handle_followup, lambda { |state|
        CveScanner.start_task_node(workflow, state, event: :handle_followup_done) do |snapshot|
          CveScanner.node_handle_followup_async(snapshot, scan_id: scan_id)
        end
      }

      wait_state :awaiting_check_approval
      wait_state :awaiting_remediation_approval
      wait_state :awaiting_followup

      transition from: :gather_scan_info, on: :gather_scan_info_done, to: :check_cve_data,
        action: ->(_state, event) { CveScanner.async_event_state(event) }

      transition from: :check_cve_data,
        guard: ->(state) {
          checkable = state.cve_ids.reject do |id|
            %w[not_found no_packages].include?(state.vulnerability_status[id])
          end
          checkable.empty?
        },
        to: :report
      transition from: :check_cve_data, to: :propose_checks

      transition from: :propose_checks, on: :propose_checks_done,
        guard: ->(_state, event) { CveScanner.async_event_state(event).check_decision == "need_more" },
        to: :awaiting_check_approval,
        action: ->(_state, event) { CveScanner.async_event_state(event) }
      transition from: :propose_checks, on: :propose_checks_done, to: :report,
        action: ->(_state, event) { CveScanner.async_event_state(event) }

      transition from: :awaiting_check_approval, on: :approve_checks, to: :run_checks
      transition from: :run_checks, on: :run_checks_done, to: :evaluate_checks,
        action: ->(_state, event) { CveScanner.async_event_state(event) }
      transition from: :evaluate_checks, on: :evaluate_checks_done,
        guard: ->(_state, event) { CveScanner.async_event_state(event).check_decision == "need_more" },
        to: :propose_checks,
        action: ->(_state, event) { CveScanner.async_event_state(event) }
      transition from: :evaluate_checks, on: :evaluate_checks_done, to: :report,
        action: ->(_state, event) { CveScanner.async_event_state(event) }

      transition from: :propose_remediation, on: :propose_remediation_done,
        guard: ->(_state, event) { CveScanner.async_event_state(event).remediation_decision == "need_more" },
        to: :awaiting_remediation_approval,
        action: ->(_state, event) { CveScanner.async_event_state(event) }
      transition from: :propose_remediation, on: :propose_remediation_done, to: :report,
        action: ->(_state, event) { CveScanner.async_event_state(event) }

      transition from: :awaiting_remediation_approval, on: :approve_remediation, to: :run_remediation
      transition from: :run_remediation, on: :run_remediation_done, to: :evaluate_remediation,
        action: ->(_state, event) { CveScanner.async_event_state(event) }
      transition from: :evaluate_remediation, on: :evaluate_remediation_done,
        guard: ->(_state, event) { CveScanner.async_event_state(event).remediation_decision == "need_more" },
        to: :propose_remediation,
        action: ->(_state, event) { CveScanner.async_event_state(event) }
      transition from: :evaluate_remediation, on: :evaluate_remediation_done, to: :report,
        action: ->(_state, event) { CveScanner.async_event_state(event) }

      transition from: :report, to: :awaiting_followup
      transition from: :awaiting_followup, on: :submit_followup, to: :handle_followup

      transition from: :handle_followup, on: :handle_followup_done,
        guard: ->(_state, event) { CveScanner.async_event_state(event).followup_decision == "answered" },
        to: :awaiting_followup,
        action: ->(_state, event) { CveScanner.async_event_state(event) }
      transition from: :handle_followup, on: :handle_followup_done,
        guard: ->(_state, event) { CveScanner.async_event_state(event).followup_decision == "reinvestigate" },
        to: :gather_scan_info,
        action: ->(_state, event) { CveScanner.async_event_state(event) }
      transition from: :handle_followup, on: :handle_followup_done,
        guard: ->(_state, event) { CveScanner.async_event_state(event).followup_decision == "remediate" },
        to: :propose_remediation,
        action: ->(_state, event) { CveScanner.async_event_state(event) }
      transition from: :handle_followup, on: :handle_followup_done,
        guard: ->(_state, event) { CveScanner.async_event_state(event).followup_decision == "report" },
        to: :report,
        action: ->(_state, event) { CveScanner.async_event_state(event) }
      transition from: :handle_followup, on: :handle_followup_done, to: :__finish__,
        action: ->(_state, event) { CveScanner.async_event_state(event) }
    end

    workflow
  end

  # Runs only through start_blocking_node. The scraper and shell commands are
  # blocking application I/O; they stay inside the bounded blocking pool.
  def self.node_gather_scan_info(state, scan_id: nil)
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
    messages.each { |message| ScanChannel.broadcast(scan_id, {type: "log", message: message}) } if scan_id

    state.merge(
      cve_ids: valid,
      os_version: os_version,
      kernel_version: kernel_version,
      cve_infos: cve_infos,
      messages: messages
    )
  end

  def self.node_check_cve_data(state, scan_id: nil)
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

    messages.each { |message| ScanChannel.broadcast(scan_id, {type: "log", message: message}) } if scan_id
    state.merge(vulnerability_status: state.vulnerability_status.merge(pre_status), messages: messages)
  end

  def self.node_propose_checks_async(state, scan_id:)
    iteration = state.check_iteration + 1

    if iteration >= MAX_LOOP_ITERATIONS
      vuln_status = best_available_status(state)
      message = "Check loop limit reached (#{MAX_LOOP_ITERATIONS}). Using best available assessment."
      ScanChannel.broadcast(scan_id, {type: "log", message: message}) if scan_id
      return completed_task(
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

    ScanChannel.broadcast(
      scan_id,
      {type: "agent_step", node: "propose_checks", message: "Round #{iteration}: asking analyst to review CVE info and propose checks..."}
    ) if scan_id

    call_agent_json_async(
      CveScanner::CveAnalystAgent,
      build_check_context(state),
      scan_id: scan_id,
      role: "CveAnalyst"
    ).map do |response|
      if response["decision"] == "done"
        vuln_status = normalize_vuln_status(response["vulnerability_status"], state.cve_ids, scan_id: scan_id)
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

  def self.node_propose_checks(state, scan_id:)
    node_propose_checks_async(state, scan_id: scan_id).wait_result
  end

  # Runs only through start_blocking_node.
  def self.node_run_checks(state, scan_id: nil)
    results = state.approved_checks.map do |command|
      {cmd: command, output: CveScanner::CommandExecutorTool.new.execute(command: command)}
    end
    results.each { |result| ScanChannel.broadcast(scan_id, {type: "log", message: "Ran: #{result[:cmd]}"}) } if scan_id
    state.merge(
      check_history: results,
      messages: results.map { |result| "Ran: #{result[:cmd]}" }
    )
  end

  def self.node_evaluate_checks_async(state, scan_id:)
    return completed_task(state, name: "cve-scanner-evaluate-noop") if state.check_decision == "done" && state.approved_checks.empty?

    if state.approved_checks.empty?
      if state.check_iteration >= MAX_LOOP_ITERATIONS
        vuln_status = best_available_status(state)
        message = "Check loop limit reached (#{MAX_LOOP_ITERATIONS}). Using best available assessment."
        ScanChannel.broadcast(scan_id, {type: "log", message: message}) if scan_id
        return completed_task(
          state.merge(
            check_decision: "done",
            vulnerability_status: vuln_status,
            messages: [message, *vuln_status.map { |id, status| "#{id}: #{status}" }]
          ),
          name: "cve-scanner-evaluate-limit"
        )
      end
      return completed_task(state.merge(check_decision: "need_more"), name: "cve-scanner-evaluate-empty")
    end

    ScanChannel.broadcast(scan_id, {type: "agent_step", node: "evaluate_checks", message: "Analyst evaluating command outputs..."}) if scan_id

    call_agent_json_async(
      CveScanner::CveAnalystAgent,
      build_check_context(state),
      scan_id: scan_id,
      role: "CveAnalyst"
    ).map do |response|
      if response["decision"] == "done" || state.check_iteration >= MAX_LOOP_ITERATIONS
        vuln_status = normalize_vuln_status(response["vulnerability_status"], state.cve_ids, scan_id: scan_id)
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

  def self.node_evaluate_checks(state, scan_id:)
    node_evaluate_checks_async(state, scan_id: scan_id).wait_result
  end

  def self.node_propose_remediation_async(state, scan_id:)
    iteration = state.remediation_iteration + 1

    if iteration >= MAX_LOOP_ITERATIONS
      message = "Remediation loop limit reached (#{MAX_LOOP_ITERATIONS})."
      ScanChannel.broadcast(scan_id, {type: "log", message: message}) if scan_id
      return completed_task(
        state.merge(
          remediation_decision: "complete",
          remediation_iteration: iteration,
          proposed_remediations: [],
          messages: [message]
        ),
        name: "cve-scanner-remediation-limit"
      )
    end

    ScanChannel.broadcast(
      scan_id,
      {type: "agent_step", node: "propose_remediation", message: "Remediation round #{iteration}: asking advisor for next steps..."}
    ) if scan_id

    call_agent_json_async(
      CveScanner::RemediationAdvisorAgent,
      build_remediation_context(state),
      scan_id: scan_id,
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

  def self.node_propose_remediation(state, scan_id:)
    node_propose_remediation_async(state, scan_id: scan_id).wait_result
  end

  # Runs only through start_blocking_node.
  def self.node_run_remediation(state, scan_id: nil)
    results = state.approved_remediations.map do |command|
      {cmd: command, output: CveScanner::CommandExecutorTool.new.execute(command: command)}
    end
    results.each { |result| ScanChannel.broadcast(scan_id, {type: "log", message: "Ran: #{result[:cmd]}"}) } if scan_id
    state.merge(
      remediation_history: results,
      messages: results.map { |result| "Ran: #{result[:cmd]}" }
    )
  end

  def self.node_evaluate_remediation_async(state, scan_id:)
    return completed_task(state.merge(remediation_decision: "complete"), name: "cve-scanner-remediation-noop") if state.approved_remediations.empty?

    ScanChannel.broadcast(
      scan_id,
      {type: "agent_step", node: "evaluate_remediation", message: "Advisor evaluating remediation results..."}
    ) if scan_id

    call_agent_json_async(
      CveScanner::RemediationAdvisorAgent,
      build_remediation_context(state),
      scan_id: scan_id,
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

  def self.node_evaluate_remediation(state, scan_id:)
    node_evaluate_remediation_async(state, scan_id: scan_id).wait_result
  end

  DONE_KEYWORDS = %w[done exit quit finish end finished bye].freeze

  def self.node_handle_followup_async(state, scan_id:)
    request = state.followup_request.to_s.strip

    if DONE_KEYWORDS.include?(request.downcase)
      farewell = "Session ended. Thank you for using CVE Scanner."
      ScanChannel.broadcast(
        scan_id,
        {type: "followup_answer", role: "FollowupAgent", answer: farewell, decision: "done"}
      ) if scan_id
      new_history = state.followup_history + [{question: request, answer: farewell}]
      return completed_task(
        state.merge(
          followup_decision: "done",
          followup_request: nil,
          followup_history: new_history,
          messages: ["Follow-up (done): #{request}"]
        ),
        name: "cve-scanner-followup-done"
      )
    end

    ScanChannel.broadcast(
      scan_id,
      {type: "agent_step", node: "handle_followup", message: "Processing follow-up: #{request.slice(0, 120)}..."}
    ) if scan_id

    call_agent_json_async(
      CveScanner::FollowupAgent,
      build_followup_context(state, request),
      scan_id: scan_id,
      role: "FollowupAgent"
    ).map do |response|
      decision = response["decision"].to_s.strip
      decision = "answered" unless %w[answered reinvestigate remediate report done].include?(decision)
      answer = response["answer"].to_s.strip
      ScanChannel.broadcast(scan_id, {type: "followup_answer", answer: answer, decision: decision}) if scan_id

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
        ScanChannel.broadcast(scan_id, {type: "status", message: "Re-investigation requested. Restarting scan..."}) if scan_id
      end

      state.merge(updates)
    end
  end

  def self.node_handle_followup(state, scan_id:)
    node_handle_followup_async(state, scan_id: scan_id).wait_result
  end

  def self.node_report(state, scan_id: nil)
    if scan_id
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
      ScanChannel.broadcast(
        scan_id,
        {
          type: "scan_report",
          vulnerability_status: state.vulnerability_status,
          check_iterations: state.check_iteration,
          remediation_iterations: state.remediation_iteration,
          cve_details: cve_details
        }
      )
    end

    summary = state.vulnerability_status.map { |id, status| "#{id}: #{status.upcase}" }.join(", ")
    state.merge(messages: ["Report generated. #{summary}"])
  end

  def self.mock_agent_response(agent_class, prompt, scan_id:, role:)
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

    if scan_id
      ScanChannel.broadcast(scan_id, {type: "chat_turn_start", role: role, prompt_preview: "[MOCK] #{prompt.slice(0, 180)}"})
      ScanChannel.broadcast(scan_id, {type: "chat_turn_done", role: role, content: response.to_json})
    end
    response
  end

  def self.normalize_vuln_status(raw_status, cve_ids, scan_id: nil)
    raw = raw_status.is_a?(Hash) ? raw_status : {}
    mangled = raw.keys.reject { |key| key.match?(/\ACVE-\d{4}-\d{4,}\z/i) }
    missing = cve_ids.reject { |id| raw.key?(id) }
    if mangled.any? && missing.any?
      message = "WARNING: LLM returned unrecognised key(s) [#{mangled.join(", ")}] — expected [#{missing.join(", ")}]. Forcing to 'unknown'."
      ScanChannel.broadcast(scan_id, {type: "log", message: message}) if scan_id
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
