# frozen_string_literal: true

require "tmpdir"
require_relative "workflow"
require_relative "delivery"

module WorkflowChild
  module_function

  def check(value, expected)
    raise "Expected #{expected.inspect}, got #{value.inspect}" unless value == expected
  end

  def run(dir, approved:)
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
    x.merge!(host.perform(a, "open-X", "workflow/X", x.merge("kind" => "open", "text" => "apply")))
    request = host.ack(host.receive(a, "dispatch/#{x.fetch("child")}"))
    check(request.fetch("execution"), x.fetch("child"))
    check(host.perform(a, "wrong-open-Y", "workflow/Y", y.merge("kind" => "open", "text" => "ping", "child" => x.fetch("child"))),
      {"status" => "wrong_child"})
    y.merge!(host.perform(a, "open-Y", "workflow/Y", y.merge("kind" => "open", "text" => "ping")))
    y_dispatch_id = "dispatch/#{y.fetch("child")}"
    check(host.ack(host.receive(a, y_dispatch_id)), {"status" => "deferred"})
    check(host.lookup(y_dispatch_id).fetch("status"), "parked")
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
    x_result_id = "result/#{x.fetch("child")}"
    first = host.receive(b, x_result_id)
    expected_outcome = approved ? "completed" : "rejected"
    check(stores.agent.observe_execution(agent_id: "S", execution_id: x.fetch("child")).status.to_s, expected_outcome)
    check(first.value, {"status" => "applied", "outcome" => expected_outcome, "output" => approved ? "approved" : nil})
    check(host.recover_import(first), false)
    b.stop!
    raise "Fault injection failed" unless b.process.value.signaled?
    check(host.recover_import(first), true)
    check(host.ack(host.receive(a, x_result_id)), {"status" => "already_applied"})
    check(stores.workflow.load("X").fetch(:snapshot).fetch("fields").values_at("imports", "child_outcome"), [1, expected_outcome])
    check(stores.workflow.load("Y").fetch(:snapshot).fetch("phase"), "awaiting_child")

    # Y owns a distinct result from the same Agent and imports it on its own delivery.
    check(host.ack(host.receive(a, "result/#{y.fetch("child")}")),
      {"status" => "applied", "outcome" => "completed", "output" => "other job finished"})
    check(stores.workflow.load("Y").fetch(:snapshot).fetch("fields").fetch("imports"), 1)
    recorded = File.exist?(effects) ? File.readlines(effects, chomp: true) : []
    check(recorded, approved ? [b.process.pid.to_s] : [])
    puts "#{expected_outcome}: A=#{a.process.pid} B=#{b.process.pid} shared Agent S; X=#{x.fetch("child")} Y=#{y.fetch("child")}"
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
  Dir.mktmpdir("workflow-child") { |dir| WorkflowChild.run(dir, approved: mode == "approve") }
end
