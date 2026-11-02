# frozen_string_literal: true

require "tmpdir"
require_relative "workflow"
require_relative "delivery"

module WorkflowChild
  module_function

  def check(value, expected)
    raise "Expected #{expected.inspect}, got #{value.inspect}" unless value == expected
  end

  def check_reserved_id(host, id, target, input)
    host.submit(id, target, input)
    raise "Accepted reserved request ID #{id}"
  rescue ArgumentError => error
    raise unless error.message == "Reserved host request ID: #{id}"
    check(host.lookup(id), nil)
  end

  def run(dir, approved:, crash_before_reply:)
    path = File.join(dir, "demo.sqlite3")
    effects = File.join(dir, "tool.log")
    stores = WorkerApproval.stores(path, install: true)
    WorkerApproval::Conversation.create(agent_id: "S", persistence: stores.agent).unload!
    host = Supervisor.new(path)
    script = File.join(__dir__, "worker.rb")
    a = WorkerApproval::WorkerProcess.new(path, effects, script: script)
    b = WorkerApproval::WorkerProcess.new(path, effects, script: script)
    raise "Expected distinct worker processes" if a.process.pid == b.process.pid

    # Each durable parent wait contains a stable, host-assigned child ID before dispatch.
    x = {"parent" => "X", "agent" => "S"}
    y = {"parent" => "Y", "agent" => "S"}
    check_reserved_id(host, "dispatch/workflow-child-v1:X", "agent/S", x.merge("kind" => "dispatch"))
    x.merge!(host.perform(a, "open-X", "workflow/X", x.merge("kind" => "open", "text" => "apply")))
    request = host.ack(host.receive(a, "dispatch/#{x.fetch("child")}"))
    check(request.fetch("execution"), x.fetch("child"))
    check(host.perform(a, "wrong-open-Y", "workflow/Y", y.merge("kind" => "open", "text" => "ping", "child" => x.fetch("child"))),
      {"status" => "wrong_child"})
    y.merge!(host.perform(a, "open-Y", "workflow/Y", y.merge("kind" => "open", "text" => "ping")))
    y_dispatch_id = "dispatch/#{y.fetch("child")}"
    check(host.ack(host.receive(a, y_dispatch_id)), {"status" => "deferred"})
    check(host.lookup(y_dispatch_id).fetch("status"), "parked")
    x_result_id = "result/#{x.fetch("child")}"
    check_reserved_id(host, x_result_id, "workflow/X", x.merge("kind" => "deliver"))
    check(host.perform(b, "early-X", "workflow/X", x.merge("kind" => "deliver")), {"status" => "not_completed"})

    check(host.perform(a, "wrong-child-Y", "workflow/Y", y.merge("kind" => "deliver", "child" => x.fetch("child"))),
      {"status" => "wrong_child"})

    # B reloads S and answers the original approval. The result message has no output field.
    answer = x.merge("kind" => "answer", "approval" => request.fetch("approval"), "approved" => approved)
    check(host.perform(b, "wrong-answer", "agent/S", answer.merge("approval" => "unknown")), {"status" => "no_matching_approval"})
    check(host.perform(b, "answer-S-X", "agent/S", answer).fetch("execution"), x.fetch("child"))
    check(host.submit("answer-S-X", "agent/S", answer).fetch("status"), "done")
    # Terminal ACK promoted the original parked row; no caller submits Y again.
    check(host.ack(host.receive(a, y_dispatch_id)).fetch("execution"), y.fetch("child"))
    expected_outcome = approved ? "completed" : "rejected"
    check(stores.agent.observe_execution(agent_id: "S", execution_id: x.fetch("child")).status.to_s, expected_outcome)
    begin
      if crash_before_reply
        host.ack(host.receive(b, x_result_id, command: "run-and-crash-before-reply"))
      else
        first = host.receive(b, x_result_id)
        check(first.value, {"status" => "applied", "outcome" => expected_outcome, "output" => approved ? "approved" : nil})
        check(host.recover_import(b), false)
        b.stop!
        host.ack(first)
      end
      raise "Expected worker death before ACK"
    rescue EOFError, Errno::EPIPE
      check(b.process.value.termsig, Signal.list.fetch("KILL"))
    end
    check(host.lookup(x_result_id).fetch("status"), "queued")
    saved = stores.workflow.load("X").fetch(:snapshot)
    check(saved.fetch("phase"), "__end__")
    check(saved.fetch("fields").values_at("imports", "child_outcome", "consumed_revision", "output"),
      [1, expected_outcome, x.fetch("revision"), approved ? "approved" : nil])
    replay = host.receive(a, x_result_id)
    check(host.recover_import(b), false)
    check(host.ack(replay), {"status" => "already_applied"})
    check(host.lookup(x_result_id).fetch("status"), "done")
    check(stores.workflow.load("X").fetch(:snapshot), saved)
    check(stores.workflow.load("Y").fetch(:snapshot).fetch("phase"), "awaiting_child")

    # Y owns a distinct result from the same Agent and imports it on its own delivery.
    check(host.ack(host.receive(a, "result/#{y.fetch("child")}")),
      {"status" => "applied", "outcome" => "completed", "output" => "other job finished"})
    check(stores.workflow.load("Y").fetch(:snapshot).fetch("fields").fetch("imports"), 1)
    recorded = File.exist?(effects) ? File.readlines(effects, chomp: true) : []
    check(recorded, approved ? [b.process.pid.to_s] : [])
    puts "#{expected_outcome}: A=#{a.process.pid} B=#{b.process.pid} shared Agent S; X=#{x.fetch("child")} Y=#{y.fetch("child")}; crash #{crash_before_reply ? "before" : "after"} result reply"
    puts "parent imports: X=1 Y=1; Tool calls=#{recorded.size}; pre-ACK redelivery: already_applied"
  ensure
    a&.close
    b&.close
    WorkerApproval::Record.connection_pool.disconnect! if WorkerApproval::Record.connected?
  end
end

modes = ARGV.empty? ? %w[approve reject] : ARGV
abort "Usage: ruby run.rb [approve|reject]" unless (modes - %w[approve reject]).empty?
modes.each do |mode|
  [true, false].each do |crash_before_reply|
    Dir.mktmpdir("workflow-child") { |dir| WorkflowChild.run(dir, approved: mode == "approve", crash_before_reply: crash_before_reply) }
  end
end
