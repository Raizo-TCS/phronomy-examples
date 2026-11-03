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
    raise "Expected separate workers" if a.process.pid == b.process.pid

    ticket = call(a, "start")
    check(call(b, "restore", "ticket" => ticket), {"restored" => ticket})
    check(call(a, "other"), {"other" => "other job finished"})
    check(File.exist?(effects), false)
    approved = decision == "approve"
    result = call(b, "answer", "approved" => approved)
    child_status = approved ? "completed" : "rejected"
    check(result, {"parent" => "completed", "child" => child_status})
    calls = File.exist?(effects) ? File.readlines(effects, chomp: true) : []
    check(calls, approved ? [b.process.pid.to_s] : [])
    check(a.process.alive? && b.process.alive?, true)
    puts "#{decision}: child=#{child_status} parent=completed Tool calls=#{calls.length}; A=#{a.process.pid} B=#{b.process.pid}"
  ensure
    a&.close
    b&.close
    WorkerApproval::Record.connection_pool.disconnect! if WorkerApproval::Record.connected?
  end
end

decisions = ARGV.empty? ? %w[approve reject] : ARGV
abort "Usage: ruby run.rb [approve|reject]" unless (decisions - %w[approve reject]).empty?
decisions.each { |decision| Dir.mktmpdir("native-child") { |dir| NativeChild.run(dir, decision) } }
