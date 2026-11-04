# frozen_string_literal: true

require "json"
require "tmpdir"
require "timeout"
require "webmock"

require_relative "../../36_native_child_approval/agents"
require_relative "../../34_worker_approval/worker_process"
require_relative "../support/chat_stub"

class MatrixParent < Phronomy::MultiAgent::Orchestrator
  agent_definition id: "matrix-two-children", version: 1
  model "gpt-4o-mini"
  provider :openai
  subagent :left, NativeChild::Child
  subagent :right, NativeChild::Child
end

module ApprovalMatrix
  module_function

  def assert_equal(expected, actual)
    raise "Expected #{expected.inspect}, got #{actual.inspect}" unless expected == actual
  end

  def batch(calls)
    {role: "assistant", content: nil, tool_calls: calls.flat_map { |name, args| ExampleChatStub.tool(name, args).fetch(:tool_calls) }}
  end

  def fixed_provider
    WebMock.enable!
    WebMock.disable_net_connect!
    RubyLLM.configure do |config|
      config.openai_protocol = :chat_completions
      config.openai_api_base = "https://example.test/v1"
      config.openai_api_key = "offline"
    end
    ExampleChatStub.new do |body, _index|
      last = body.fetch("messages").last
      names = body.fetch("tools").map { |item| item.fetch("function").fetch("name") }
      if last.fetch("role") == "tool"
        names.include?("dispatch_to_left") ? "parent finished" : "child finished"
      elsif names.include?("dispatch_to_left")
        siblings = last.fetch("content") == "siblings"
        calls = [["dispatch_to_left", {input: siblings ? "gate left" : "two tools"}]]
        calls << ["dispatch_to_right", {input: "gate right"}] if siblings
        batch(calls)
      elsif last.fetch("content") == "two tools"
        batch([["apply_request", {}], ["publish_request", {}]])
      else
        ExampleChatStub.tool("apply_request")
      end
    end
  end

  def listener(queue)
    ->(event) { queue << event.payload.fetch(:request) if event.type == :approval_required }
  end

  def next_request(queue, store)
    request = Timeout.timeout(12) { queue.pop }
    identity = store.execution_identity(request.execution_id)
    assert_equal(["parent", "run"], identity.correlation.values_at("parent_agent_id", "parent_execution_id"))
    {agent: identity.agent_id, execution: request.execution_id, id: request.id, items: request.items.map(&:tool_name).sort}
  end

  def serve(path)
    fixture = fixed_provider
    stores = WorkerApproval.stores(path)
    events = Queue.new
    parent = nil
    hosted = nil
    $stdout.sync = true
    $stdin.each_line do |line|
      cmd = JSON.parse(line, symbolize_names: true)
      response = case cmd.fetch(:op)
      when "start"
        parent = MatrixParent.create(agent_id: "parent", persistence: stores.agent, coordination_store: stores.multi_agent, on_event: listener(events))
        reservation = Phronomy::Agent::ReservedExecution.new(agent_id: "parent", execution_id: "run")
        hosted = parent.start_hosted(reservation: reservation, input: cmd.fetch(:input))
        begin
          next_request(events, stores.agent)
        rescue Timeout::Error
          warn "No initial approval after #{fixture.calls.length} provider calls"
          hosted.wait_result(timeout: 1)
          raise
        end
      when "request"
        next_request(events, stores.agent)
      when "detach"
        ticket = cmd.fetch(:ticket)
        wait = hosted.detach!(execution_id: ticket.fetch(:execution), approval_request_id: ticket.fetch(:id))
        assert_equal([wait.execution_id, wait.approval_request_id], ticket.values_at(:execution, :id))
        assert_equal(nil, MatrixParent.get("parent"))
        assert_equal(nil, NativeChild::Child.get(ticket.fetch(:agent)))
        {result: "detached"}
      when "restore"
        parent = MatrixParent.load("parent", persistence: stores.agent, coordination_store: stores.multi_agent, on_event: listener(events))
        pending = parent.resume_async("run")
        ticket = next_request(events, stores.agent)
        begin
          pending.wait_result(timeout: 12)
          raise "Parent completed before child approval"
        rescue Phronomy::ExecutionRehydrationRequiredError
          # The parent still awaits the saved child.
        end
        ticket
      when "answer"
        ticket = cmd.fetch(:ticket)
        child = NativeChild::Child.get(ticket.fetch(:agent))
        result = child.approve(ticket.fetch(:execution), approval_request_id: ticket.fetch(:id), approved: cmd.fetch(:approve))
        assert_equal(ticket.fetch(:execution), result.fetch(:execution_id))
        {status: stores.agent.observe_execution(agent_id: ticket.fetch(:agent), execution_id: ticket.fetch(:execution)).status}
      when "complete"
        result = parent.resume("run")
        assert_equal("parent finished", result.fetch(:output))
        count = fixture.calls.length
        assert_equal(result, parent.resume("run"))
        assert_equal(count, fixture.calls.length)
        {status: stores.agent.observe_execution(agent_id: "parent", execution_id: "run").status}
      when "observe"
        targets = [["parent", "run"]] + cmd.fetch(:tickets).map { |ticket| ticket.values_at(:agent, :execution) }
        targets.map { |agent_id, execution_id| stores.agent.observe_execution(agent_id: agent_id, execution_id: execution_id).status }
      else
        raise "Unknown command: #{cmd.inspect}"
      end
      puts JSON.generate(response)
    end
  end

  def call(worker, op, **args)
    worker.send_command(JSON.generate(args.merge(op: op)))
    worker.receive
  end

  def run(scenario, dir)
    path = File.join(dir, "state.sqlite3")
    log = File.join(dir, "effects.log")
    WorkerApproval.stores(path, install: true)
    a = WorkerApproval::WorkerProcess.new(path, log, script: __FILE__)
    b = WorkerApproval::WorkerProcess.new(path, log, script: __FILE__)
    raise "Distinct live workers required" if a.process.pid == b.process.pid
    siblings = scenario == "siblings"
    ticket = call(a, "start", input: siblings ? "siblings" : "batch")
    assert_equal(siblings ? ["apply_request"] : %w[apply_request publish_request], ticket.fetch("items"))
    assert_equal(false, File.exist?(log))
    if siblings
      other = call(a, "request")
      raise "Expected two distinct child executions" if ticket.fetch("execution") == other.fetch("execution")
      raise "Expected two distinct child Agents" if ticket.fetch("agent") == other.fetch("agent")
      assert_equal(%w[suspended suspended], call(b, "observe", tickets: [ticket, other]).drop(1))
      assert_equal(["apply_request"], other.fetch("items"))
      assert_equal({"status" => "completed"}, call(a, "answer", ticket: ticket, approve: true))
      assert_equal(%w[completed suspended], call(b, "observe", tickets: [ticket, other]).drop(1))
      assert_equal({"status" => "rejected"}, call(a, "answer", ticket: other, approve: false))
      assert_equal({"status" => "completed"}, call(a, "complete"))
      assert_equal(%w[completed completed rejected], call(b, "observe", tickets: [ticket, other]))
      states = "parent=completed children=completed,rejected"
      expected_effects = [a.process.pid.to_s]
    else
      assert_equal({"result" => "detached"}, call(a, "detach", ticket: ticket))
      assert_equal(ticket, call(b, "restore"))
      approved = scenario == "batch-approve"
      status = approved ? "completed" : "rejected"
      assert_equal({"status" => status}, call(b, "answer", ticket: ticket, approve: approved))
      assert_equal({"status" => "completed"}, call(b, "complete"))
      assert_equal(["completed", status], call(a, "observe", tickets: [ticket]))
      states = "parent=completed child=#{status} approval_items=2 transferred=true"
      expected_effects = approved ? [b.process.pid.to_s, "published by #{b.process.pid}"] : []
    end
    actual_effects = File.exist?(log) ? File.readlines(log, chomp: true) : []
    assert_equal(expected_effects.sort, actual_effects.sort)
    assert_equal(true, [a, b].all? { |worker| worker.process.alive? })
    puts "#{scenario}: #{states} effects=#{actual_effects.length} A=#{a.process.pid} B=#{b.process.pid} PASS"
  ensure
    a&.close
    b&.close
    WorkerApproval::Record.connection_pool.disconnect! if WorkerApproval::Record.connected?
  end
end

if ARGV.first&.end_with?(".sqlite3")
  ApprovalMatrix.serve(ARGV.fetch(0))
else
  cases = %w[batch-approve batch-reject siblings]
  abort "Unknown scenario" unless (ARGV - cases).empty?
  (ARGV.empty? ? cases : ARGV).each do |scenario|
    Dir.mktmpdir("approval-matrix") { |dir| ApprovalMatrix.run(scenario, dir) }
  end
end
