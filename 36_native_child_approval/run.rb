# frozen_string_literal: true

require "tmpdir"
require_relative "agents"
require_relative "../34_worker_approval/worker_process"

module NativeChild
  def self.call(worker, op, fields = {})
    worker.send_command(JSON.generate(fields.merge("op" => op)))
    worker.receive
  end

  def self.run(dir, decision)
    path = File.join(dir, "agents.sqlite3")
    effects = File.join(dir, "tool.log")
    WorkerApproval.stores(path, install: true)
    script = File.join(__dir__, "worker.rb")
    a = WorkerApproval::WorkerProcess.new(path, effects, script: script)
    b = WorkerApproval::WorkerProcess.new(path, effects, script: script)
    repeat = %w[approve-twice reject-second].include?(decision)
    c = WorkerApproval::WorkerProcess.new(path, effects, script: script) if repeat
    workers = [a, b, c].compact
    check(workers.map { |w| w.process.pid }.uniq.size, workers.size)

    ticket = call(a, "start", "input" => (repeat ? "apply then publish" : "use the child"))
    check(call(b, "restore", "ticket" => ticket), {"restored" => ticket})
    check(call(a, "other"), {"other" => "other job finished"})
    check(File.exist?(effects), false)
    if repeat
      next_ticket = call(b, "approve_and_handoff")
      check(next_ticket.except("approval"), ticket.except("approval"))
      raise "Expected two different approval IDs" if next_ticket.fetch("approval") == ticket.fetch("approval")
      check(call(c, "restore", "ticket" => next_ticket), {"restored" => next_ticket})
      first_id = ticket.fetch("approval")
      check(call(c, "replay", "approval" => first_id), {"refused" => first_id})
      check(call(b, "other"), {"other" => "other job finished"})
      check(File.readlines(effects, chomp: true), [b.process.pid.to_s])
    end

    approved = %w[approve approve-twice].include?(decision)
    result = call(c || b, "answer", "approved" => approved)
    child_status = approved ? "completed" : "rejected"
    check(result, {"parent" => "completed", "child" => child_status})
    calls = File.exist?(effects) ? File.readlines(effects, chomp: true) : []
    expected = (repeat || approved) ? [b.process.pid.to_s] : []
    expected << "published by #{c.process.pid}" if repeat && approved
    check(calls, expected)
    check(workers.all? { |w| w.process.alive? }, true)
    pids = "A=#{a.process.pid} B=#{b.process.pid}"
    pids += " C=#{c.process.pid}" if repeat
    puts "#{decision}: child=#{child_status} parent=completed Tool calls=#{calls.length}; #{pids}"
  ensure
    a&.close
    b&.close
    c&.close
    WorkerApproval::Record.connection_pool.disconnect! if WorkerApproval::Record.connected?
  end
end

decisions = %w[approve reject approve-twice reject-second]
abort "Usage: ruby run.rb [#{decisions.join("|")}]" unless (ARGV - decisions).empty?
(ARGV.empty? ? decisions : ARGV).each do |decision|
  Dir.mktmpdir("native-child") { |dir| NativeChild.run(dir, decision) }
end
