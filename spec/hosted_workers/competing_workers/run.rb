# frozen_string_literal: true

require "tmpdir"
require "securerandom"
require_relative "../../../34_worker_approval/conversation"
require_relative "../../../34_worker_approval/inbox"
require_relative "../../../34_worker_approval/worker_process"

module CompetingWorkers
  module_function

  def check(value, message)
    raise message unless value
  end

  def workers(count, db, effects)
    group = []
    begin
      count.times do
        worker = WorkerApproval::WorkerProcess.new(db, effects, script: File.join(__dir__, "ready_worker.rb"))
        group << worker
        check(worker.receive == {"ready" => worker.process.pid}, "worker startup failed")
      end
      yield group
    ensure
      group.each(&:close)
    end
  end

  def wave(group, expected_ids)
    # Start all claim attempts before consuming a reply. Hold the claims until
    # every worker has replied, including any worker with no eligible command.
    group.each { |worker| worker.send_command("run") }
    claims = {}
    group.each do |worker|
      message = worker.receive
      next if message == {"idle" => true}
      id = message.fetch("request")
      check(!claims.key?(id) && message.fetch("pid") == worker.process.pid, "duplicate or misattributed claim")
      claims[id] = [worker, worker.receive]
    end
    check(claims.keys.sort == expected_ids.sort, "unexpected or missing requests: #{claims.keys.inspect}")
    yield claims
    claims.each_value do |worker, _|
      worker.send_command("ack")
      check(worker.receive == {"ack" => true}, "claim was not acknowledged")
    end
  end

  def verify(directory, overlap:)
    db = File.join(directory, "agents.sqlite3")
    effects = File.join(directory, "effects")
    barrier = File.join(directory, "tool-barrier")
    Dir.mkdir(barrier) if overlap
    store = WorkerApproval.store(db, install: true)
    inbox = Inbox.new(db)
    inbox.setup
    ids = {"S" => SecureRandom.uuid, "T" => SecureRandom.uuid}
    answers = {}
    start_pids = []
    ids.each do |agent, execution|
      WorkerApproval::Conversation.create(agent_id: agent, persistence: store).unload!
      inbox.submit("start-#{agent}", agent, {"kind" => "start", "execution" => execution, "text" => "apply"})
    end
    workers(2, db, effects) do |group|
      start_pids = group.map { |worker| worker.process.pid }
      wave(group, %w[start-S start-T]) do |claims|
        ids.each do |agent, execution|
          receipt = claims.fetch("start-#{agent}").last
          check(receipt.fetch("execution") == execution, "wrong execution in saved wait")
          answers[agent] = {"kind" => "answer", "execution" => execution,
            "approval" => receipt.fetch("approval"), "approved" => overlap || agent == "S"}
        end
        check(answers.values.map { |answer| answer.fetch("approval") }.uniq.size == 2, "approval IDs collide")
        check(!File.exist?(effects), "Tool ran before approval")
      end
    end
    # Enqueue T first. Redeliver both request IDs before any answer is handled.
    2.times do
      %w[T S].each { |agent| inbox.submit("answer-#{agent}", agent, answers.fetch(agent)) }
    end
    workers(3, db, effects) do |group|
      check((start_pids & group.map { |worker| worker.process.pid }).empty?, "a starter PID was reused")
      wave(group, %w[answer-T answer-S]) do |claims|
        producing_pids = []
        answers.each do |agent, answer|
          worker, result = claims.fetch("answer-#{agent}")
          expected = {"execution" => ids.fetch(agent)}
          if answer.fetch("approved")
            expected["output"] = "approved"
            producing_pids << worker.process.pid.to_s
          else
            expected["status"] = "rejected"
          end
          check(result == expected, "wrong answer result for #{agent}")
        end
        check(File.readlines(effects, chomp: true).sort == producing_pids.sort, "effect count or producing workers differ")
        check(Dir.children(barrier).sort == producing_pids.sort, "Tool barrier did not involve both workers") if overlap
      end
      answers.each do |agent, answer|
        check(inbox.submit("answer-#{agent}", agent, answer).fetch("status") == "done", "replay reopened completed work")
      end
      wave(group, []) { }
    end
    ids.each do |agent, execution|
      status = store.observe_execution(agent_id: agent, execution_id: execution).status
      expected = answers.fetch(agent).fetch("approved") ? :completed : :rejected
      check(status == expected, "wrong durable outcome for #{agent}")
    end
    summary = overlap ? "approved=2, overlapping Tool PIDs=2, effects=2" : "approved=1, rejected=1, effects=1"
    puts "PASS competing workers: 2 saved waits, 3 responders, #{summary}, duplicate delivery=0"
  ensure
    WorkerApproval::Record.connection_pool.disconnect! if WorkerApproval::Record.connected?
  end
end

[false, true].each do |overlap|
  Dir.mktmpdir("competing-workers") { |directory| CompetingWorkers.verify(directory, overlap: overlap) }
end
