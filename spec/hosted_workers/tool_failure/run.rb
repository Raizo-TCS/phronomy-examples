# frozen_string_literal: true

require "tmpdir"
require_relative "../../../36_native_child_approval/agents"
require_relative "../../../34_worker_approval/worker_process"

def call(worker, op, ticket = nil)
  worker.send_command(JSON.generate("op" => op, "ticket" => ticket))
  worker.receive
end

Dir.mktmpdir("native-child-tool-failure") do |dir|
  db = File.join(dir, "agents.sqlite3")
  effects = File.join(dir, "tool.log")
  WorkerApproval.stores(db, install: true)
  workers = []
  spawn_worker = lambda do
    worker = WorkerApproval::WorkerProcess.new(db, effects, script: File.join(__dir__, "worker.rb"))
    workers << worker
    worker
  end
  a = spawn_worker.call
  ticket = call(a, "start")
  raise "Tool ran before approval" if File.exist?(effects)
  b = spawn_worker.call
  NativeChild.check(call(b, "restore", ticket), {"restored" => ticket})
  failure = call(b, "fail")
  NativeChild.check(failure.fetch("approval").fetch("error_class"), "Phronomy::ToolError")
  raise "Tool cause missing" unless failure.fetch("approval").fetch("error").include?("injected write failure")
  NativeChild.check(failure.fetch("import").fetch("status"), "failed")
  NativeChild.check(failure.fetch("calls"), 0)

  first = call(b, "read", ticket)
  terminal_failure = ["failed", {"status" => "failed", "output" => nil}]
  NativeChild.check(first, {"outcomes" => [terminal_failure, terminal_failure], "calls" => 0})
  # Observe eligibility for pair release without making it a failure-recovery requirement.
  release = call(b, "release", ticket)

  # End B before starting a new owner, even if pair release is ineligible.
  b.close
  raise "Worker B did not exit normally" unless b.process.value.success?
  workers.delete(b)
  c = spawn_worker.call
  NativeChild.check([a, b, c].map { |worker| worker.process.pid }.uniq.size, 3)
  NativeChild.check(call(c, "read", ticket), first)
  next_turn = call(c, "next")
  NativeChild.check(next_turn.values_at("output", "calls"), ["new turn completed", 1])
  raise "Execution ID reused" if next_turn.fetch("id") == ticket.fetch("execution")
  NativeChild.check(call(c, "read", ticket), first)
  NativeChild.check(File.readlines(effects, chomp: true), [b.process.pid.to_s])
  puts "PASS Tool IOError wrapped as ToolError; child=failed parent=failed; " \
    "attempts=1 durable reread calls=0 new turn calls=1; release=#{release.fetch("released")}"
ensure
  workers&.each(&:close)
  WorkerApproval::Record.connection_pool.disconnect! if WorkerApproval::Record.connected?
end
