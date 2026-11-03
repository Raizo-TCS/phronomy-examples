# frozen_string_literal: true

require_relative "worker_process"
require "tmpdir"
require_relative "conversation"
require_relative "recovery"

module WorkerApproval
  module_function

  def check(condition, description)
    raise "Verification failed: #{description}" unless condition
  end

  def acknowledge(worker)
    worker.send_command("ack")
    check(worker.receive == {"ack" => true}, "missing ACK")
  end

  def run(mode)
    Dir.mktmpdir("worker-approval") do |dir|
      path = File.join(dir, "demo.sqlite3")
      effects = File.join(dir, "effects.log")
      store = WorkerApproval.store(path, install: true)
      %w[S T].each { |name| Conversation.create(agent_id: name, persistence: store).unload! }
      inbox = Inbox.new(path)
      inbox.setup
      id = SecureRandom.uuid
      inbox.submit("start", "S", {"kind" => "start", "execution" => id, "text" => "apply"})
      a = WorkerProcess.new(path, effects)
      b = WorkerProcess.new(path, effects)
      a.send_command("run")
      claim = a.receive
      owner = Recovery::Owner.new(process: a.process, request_id: claim.fetch("request"), token: claim.fetch("token"))
      receipt = a.receive
      check(receipt.fetch("execution") == id && claim.fetch("pid") == a.process.pid, "wrong execution or owner")
      answer = {"kind" => "answer", "execution" => id, "approval" => receipt.fetch("approval"), "approved" => true}
      inbox.submit("response", "S", answer)
      recovery = Recovery.new(inbox, store)
      check(recovery.reconcile(owner) == :owner_alive, "released a live owner")
      b.send_command("run")
      check(b.receive == {"idle" => true}, "answer overtook initial ACK")
      if mode == "crash"
        a.stop!
        check(a.process.value.signaled?, "fault injection did not terminate A")
        check(inbox.lookup("start").fetch("status") == "running", "ACK unexpectedly committed")
        check(recovery.reconcile(owner.with(token: "wrong")) == :wrong_owner, "wrong owner accepted")
        reconciled = 2.times.map { Thread.new { recovery.reconcile(owner) } }.map(&:value)
        check(reconciled.sort == [:already_recorded, :reconciled], "claim reconciled twice")
      else
        acknowledge(a)
      end
      # B claims S. While B holds it, A can claim the unrelated Agent T.
      b.send_command("run")
      b_claim = b.receive
      check(b_claim.fetch("request") == "response" && b_claim.fetch("pid") == b.process.pid, "answer misrouted")
      if mode == "normal"
        inbox.submit("other", "T", {"kind" => "start", "execution" => SecureRandom.uuid, "text" => "ping"})
        a.send_command("run")
        other = a.receive
        check(other.fetch("pid") == claim.fetch("pid") && other.fetch("request") == "other", "A not reused")
        check(a.receive.fetch("output") == "other job finished", "unexpected T result")
        acknowledge(a)
      end
      check(b.receive == {"execution" => id, "output" => "approved"}, "unexpected resumed result")
      acknowledge(b)
      check(inbox.submit("response", "S", answer).fetch("status") == "done", "duplicate input enqueued")
      b.send_command("run")
      check(b.receive == {"idle" => true}, "duplicate delivery")
      check(store.observe_execution(agent_id: "S", execution_id: id).status == :completed, "execution incomplete")
      check(File.readlines(effects, chomp: true) == [b.process.pid.to_s], "wrong Tool effects")
      puts "#{mode}: A=#{a.process.pid} B=#{b.process.pid} execution=#{id} completed; Tool calls=1"
    ensure
      a&.close
      b&.close
      Record.connection_pool.disconnect! if Record.connected?
    end
  end
end

modes = ARGV.empty? ? %w[normal crash] : ARGV
abort "Usage: ruby run.rb [normal|crash]" unless (modes - %w[normal crash]).empty?
modes.each { |mode| WorkerApproval.run(mode) }
