# frozen_string_literal: true

require_relative "inbox"

module WorkerApproval
  # The supervising parent pairs a still-owned process handle with the claim
  # received over that child's private pipe. A timeout is insufficient.
  class Recovery
    Owner = Data.define(:process, :request_id, :token)

    def initialize(inbox, store)
      @inbox, @store = inbox, store
    end

    def reconcile(owner)
      return :owner_alive unless owner.process.join(0)
      row = @inbox.lookup(owner.request_id)
      return :wrong_owner unless row && row.fetch("owner") == owner.token
      return :already_recorded if row.fetch("status") == "done"
      return :not_running unless row.fetch("status") == "running"
      input = JSON.parse(row.fetch("body"))
      return :unsupported unless input.fetch("kind") == "start"
      return :uncorrelated unless (id = input["execution"])
      wait = @store.standalone_approval_wait(agent_id: row.fetch("target"), execution_id: id)
      return :no_saved_wait unless wait
      receipt = {"execution" => wait.execution_id, "approval" => wait.approval_request_id}
      @inbox.finish(row, receipt)
      :reconciled
    rescue Inbox::StaleAcknowledgement
      current = @inbox.lookup(owner.request_id)
      raise unless current && current["owner"] == owner.token && current["status"] == "done" &&
        JSON.parse(current.fetch("result")) == receipt
      :already_recorded
    end
  end
end
