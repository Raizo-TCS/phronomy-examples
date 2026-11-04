# frozen_string_literal: true

# Run this file with the SQLite bundle from phronomy-examples.
require "tmpdir"
require "timeout"
require_relative "../../35_workflow_child_approval/handler"
require_relative "../../35_workflow_child_approval/delivery"
require_relative "../../36_native_child_approval/handler"
require_relative "../../36_native_child_approval/provider_fixture"

module WorkflowNative
  class Handler
    def initialize(stores)
      @stores = stores
      @outer = WorkflowChild::Handler.new(stores)
      @provider = NativeChild.fixed_provider
    end

    def call(job)
      input = JSON.parse(job.fetch("body"))
      kind = input.fetch("kind")
      return @outer.call(job) unless %w[dispatch answer].include?(kind)

      agent, execution = input.values_at("agent", "child")
      raise "Wrong target" unless job.fetch("target") == "agent/#{agent}"
      saved = @stores.workflow.load(input.fetch("parent"))
      snapshot = saved.fetch(:snapshot)
      fields = snapshot.fetch("fields")
      NativeChild.check([snapshot.fetch("phase"), saved.fetch(:revision), *fields.values_at("agent_id", "child_id")],
        ["awaiting_child", input.fetch("revision"), agent, execution])
      if kind == "dispatch"
        observed = @stores.agent.observe_execution(agent_id: agent, execution_id: execution)
        raise "Duplicate native dispatch" unless observed.absent?
        events = Queue.new
        parent = NativeChild::Parent.create(agent_id: agent, persistence: @stores.agent,
          coordination_store: @stores.multi_agent,
          on_event: ->(event) { events << event.payload.fetch(:request) if event.type == :approval_required })
        reservation = Phronomy::Agent::ReservedExecution.new(agent_id: agent, execution_id: execution)
        hosted = parent.start_hosted(reservation: reservation, input: fields.fetch("text"))
        request = Timeout.timeout(12) { events.pop }
        NativeChild.check(request.items.map(&:tool_name), ["apply_request"])
        identity = @stores.agent.execution_identity(request.execution_id)
        NativeChild.check(identity.correlation.values_at("parent_agent_id", "parent_execution_id"), [agent, execution])
        hosted.detach!(execution_id: request.execution_id, approval_request_id: request.id)
        {"ticket" => {"parent" => agent, "execution" => execution, "child" => identity.agent_id,
                      "child_execution" => request.execution_id, "approval" => request.id}}
      else
        ticket = input.fetch("ticket")
        NativeChild.check(ticket.values_at("parent", "execution"), [agent, execution])
        native = NativeChild::Handler.new(@stores, @provider)
        native.restore(ticket)
        NativeChild.check(native.answer(true), {"parent" => "completed", "child" => "completed"})
        {"output" => @stores.agent.observe_execution(agent_id: agent, execution_id: execution).result}
      end
    end
  end

  def self.run(workdir, worker_script)
    path = File.join(workdir, "state.sqlite3")
    effects = File.join(workdir, "tool.log")
    stores = WorkerApproval.stores(path, install: true)
    host = WorkflowChild::Supervisor.new(path)
    workers = []
    3.times { workers << WorkerApproval::WorkerProcess.new(path, effects, script: worker_script) }
    starter, approver, importer = workers
    pids = workers.map { |worker| worker.process.pid }
    NativeChild.check(pids.uniq.size, 3)
    workflow = "outer"
    agent = "orchestrator"
    target = "workflow/#{workflow}"
    address = {"parent" => workflow, "agent" => agent}
    start = host.perform(starter, "open", target, address.merge("kind" => "open", "text" => "use the child"))
    address.merge!(start)
    execution = start.fetch("child")
    ticket = host.ack(host.receive(starter, "dispatch/#{execution}")).fetch("ticket")
    raise "Tool executed before approval" if File.exist?(effects)
    result = host.perform(approver, "answer", "agent/#{agent}", address.merge("kind" => "answer", "ticket" => ticket))
    NativeChild.check(result.fetch("output"), "received: child finished")
    result_id = "result/#{execution}"
    begin
      host.receive(importer, result_id, command: "run-and-crash-before-reply")
      raise "Expected a killed result importer"
    rescue EOFError, Errno::EPIPE
      NativeChild.check(importer.process.value.termsig, Signal.list.fetch("KILL"))
    end
    committed = stores.workflow.load(workflow)
    snapshot = committed.fetch(:snapshot)
    NativeChild.check(snapshot.fetch("phase"), "__end__")
    NativeChild.check(snapshot.fetch("fields").values_at("imports", "output", "consumed_revision"),
      [1, "received: child finished", start.fetch("revision")])
    NativeChild.check(host.lookup(result_id).fetch("status"), "queued")
    NativeChild.check(host.ack(host.receive(starter, result_id)), {"status" => "already_applied"})
    NativeChild.check(host.lookup(result_id).fetch("status"), "done")
    NativeChild.check(stores.workflow.load(workflow), committed)
    child = stores.agent.observe_execution(agent_id: ticket.fetch("child"), execution_id: ticket.fetch("child_execution"))
    NativeChild.check([child.status, child.result], [:completed, "child finished"])
    NativeChild.check(stores.agent.observe_execution(agent_id: agent, execution_id: execution).status, :completed)
    NativeChild.check(File.readlines(effects, chomp: true), [approver.process.pid.to_s])
    puts "PASS starter/replayer=#{pids[0]} approver/tool=#{pids[1]} killed-importer=#{pids[2]}"
    puts "Workflow opens -> Orchestrator -> native child -> Tool approval -> parent completion -> Workflow result"
    puts "Workflow imports=1; approved Tool effects=1; SIGKILL after commit before reply/ACK; replay=already_applied"
  ensure
    workers&.each(&:close)
    WorkerApproval::Record.connection_pool.disconnect! if WorkerApproval::Record.connected?
  end
end

if ARGV.empty?
  Dir.mktmpdir("workflow-native") { |dir| WorkflowNative.run(dir, File.expand_path(__FILE__)) }
else
  # Example 34 provides the deterministic process transport. Install the native
  # provider fixture after loading the transport's standalone Agent fixture.
  require_relative "../../34_worker_approval/worker_host"
  path = ARGV.fetch(0)
  WorkerApproval.serve(WorkflowChild::DispatchInbox.new(path), WorkflowNative::Handler.new(WorkerApproval.stores(path)))
end
