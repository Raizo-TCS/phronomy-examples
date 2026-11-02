# frozen_string_literal: true

require_relative "../34_worker_approval/inbox"
require_relative "../34_worker_approval/worker_process"

module WorkflowChild
  # Holds the private process handle together with the exact claim it reported.
  Delivery = Data.define(:worker, :claim, :value)

  class DispatchInbox < Inbox
    def finish(job, value)
      input = JSON.parse(job.fetch("body"))
      kind = input.fetch("kind")
      opened = kind == "open" && value.key?("revision")
      blocked = kind == "dispatch" && value["status"] == "deferred"
      terminal = %w[dispatch answer].include?(kind) && (value.key?("output") || value["status"] == "rejected")
      return super unless opened || blocked || terminal

      # Persist follow-ups in this delivery's ACK transaction. A later worker
      # can claim a durable row even if this worker exits after returning.
      Database.open(@database) do |db|
        db.transaction(:immediate) do
          status = blocked ? "parked" : "done"
          finish_claim(db, job, status: status, result: value)
          if opened
            call = input.slice("parent", "agent").merge(value.slice("child", "revision"))
            insert_or_lookup(db, "dispatch/#{call.fetch("child")}", "agent/#{call.fetch("agent")}", call.merge("kind" => "dispatch"))
          elsif terminal
            call = input.slice("parent", "agent", "child", "revision")
            insert_or_lookup(db, "result/#{call.fetch("child")}", "workflow/#{call.fetch("parent")}", call.merge("kind" => "deliver"))
            db.execute("UPDATE inbox SET status='queued',owner=NULL,result=NULL WHERE target=? AND status='parked'",
              [job.fetch("target")])
          end
        end
      end
    end
  end

  class Supervisor
    def initialize(path)
      @path = path
      @inbox = DispatchInbox.new(path)
      @inbox.setup
    end

    def submit(id, target, body)
      @inbox.submit(id, target, body)
    end

    def lookup(id) = @inbox.lookup(id)

    def receive(worker, id)
      worker.send_command("run")
      claim = worker.receive
      unless claim.fetch("request") == id && claim.fetch("pid") == worker.process.pid
        raise "Unexpected claim for #{id}: #{claim.inspect}"
      end
      Delivery.new(worker: worker, claim: claim, value: worker.receive)
    end

    def perform(worker, id, target, body)
      submit(id, target, body)
      ack(receive(worker, id))
    end

    def ack(delivery)
      delivery.worker.send_command("ack")
      raise "Missing ACK" unless delivery.worker.receive == {"ack" => true}
      delivery.value
    end

    # Only parent-result import has a replay receipt in the Workflow snapshot.
    def recover_import(delivery)
      return false unless delivery.worker.process.join(0)
      id = delivery.claim.fetch("request")
      row = @inbox.lookup(id)
      return false unless row && JSON.parse(row.fetch("body")).fetch("kind") == "deliver"
      Database.open(@path) do |db|
        db.execute("UPDATE inbox SET status='queued',owner=NULL WHERE request_id=? AND status='running' AND owner=?",
          [id, delivery.claim.fetch("token")])
        db.changes == 1
      end
    end
  end
end
