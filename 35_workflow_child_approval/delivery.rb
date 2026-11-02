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
      @inflight = {}
      @inbox = DispatchInbox.new(path)
      @inbox.setup
    end

    def submit(id, target, body)
      raise ArgumentError, "Reserved host request ID: #{id}" if id.start_with?("dispatch/", "result/")
      @inbox.submit(id, target, body)
    end

    def lookup(id) = @inbox.lookup(id)

    def receive(worker, id, command: "run")
      raise "Worker already owns a delivery" if @inflight.key?(worker)
      claim = read_reply(worker, command)
      unless claim.fetch("request") == id && claim.fetch("pid") == worker.process.pid
        raise "Unexpected claim for #{id}: #{claim.inspect}"
      end
      # Keep the claim even if the next pipe read fails before a Delivery exists.
      claim.each_value(&:freeze)
      @inflight[worker] = claim.freeze
      Delivery.new(worker: worker, claim: claim, value: read_reply(worker))
    end

    def perform(worker, id, target, body)
      submit(id, target, body)
      ack(receive(worker, id))
    end

    def ack(delivery)
      worker = delivery.worker
      raise Inbox::StaleAcknowledgement unless @inflight[worker].equal?(delivery.claim)
      raise "Missing ACK" unless read_reply(worker, "ack") == {"ack" => true}
      @inflight.delete(worker)
      delivery.value
    end

    # Only parent-result import has a replay receipt in the Workflow snapshot.
    def recover_import(worker)
      claim = @inflight[worker]
      return false unless claim && worker.process.join(0)
      requeued = Database.open(@path) do |db|
        db.execute(<<~SQL, [claim.fetch("request"), claim.fetch("token")])
          UPDATE inbox SET status='queued', owner=NULL
          WHERE request_id=? AND owner=? AND status='running' AND json_extract(body, '$.kind')='deliver'
        SQL
        db.changes == 1
      end
      @inflight.delete(worker)
      requeued
    end

    private

    def read_reply(worker, command = nil)
      worker.send_command(command) if command
      worker.receive
    rescue EOFError, Errno::EPIPE
      # A closed pipe alone does not prove loss of ownership. If reaping times
      # out, retain the claim so the supervisor can check the process again.
      recover_import(worker) if @inflight.key?(worker) && worker.process.join(5)
      raise
    end
  end
end
