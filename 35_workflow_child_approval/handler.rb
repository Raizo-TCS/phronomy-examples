# frozen_string_literal: true

require_relative "workflow"
require_relative "../34_worker_approval/handler"

module WorkflowChild
  class Handler
    def initialize(stores)
      @stores = stores
      @workflow = WorkflowChild.definition(stores.workflow)
      @agent = WorkerApproval::Handler.new(stores.agent)
    end

    def call(job)
      input = JSON.parse(job.fetch("body"))
      parent = input.fetch("parent")
      kind = input.fetch("kind")
      agent_target = %w[dispatch answer].include?(kind)
      expected_target = agent_target ? "agent/#{input.fetch("agent")}" : "workflow/#{parent}"
      raise ArgumentError, "Wrong claimed target" unless job.fetch("target") == expected_target

      return open_parent(parent, input) if kind == "open"

      record = @stores.workflow.load(parent)
      return {"status" => "wrong_parent"} unless record
      snapshot = record.fetch(:snapshot)
      fields = snapshot.fetch("fields")
      unless fields.values_at("agent_id", "child_id") == input.values_at("agent", "child")
        return {"status" => "wrong_child"}
      end
      revision = input.fetch("revision")
      if kind == "deliver" && fields.fetch("imports") == 1 && fields["consumed_revision"] == revision && snapshot.fetch("phase") == "__end__"
        return {"status" => "already_applied"}
      end
      unless record.fetch(:revision) == revision && snapshot.fetch("phase") == "awaiting_child"
        return {"status" => "stale_wait"}
      end

      agent = fields.fetch("agent_id")
      child = fields.fetch("child_id")
      case kind
      when "dispatch"
        observed = @stores.agent.observe_execution(agent_id: agent, execution_id: child)
        return {"status" => "already_dispatched"} unless observed.absent?
        return {"status" => "deferred"} unless @stores.agent.active_executions(agent_id: agent).empty?
        @agent.start(agent, {"execution" => child, "text" => fields.fetch("text")})
      when "answer"
        approved = input.fetch("approved")
        raise ArgumentError, "Expected a boolean approval" unless [true, false].include?(approved)
        wait = @stores.agent.standalone_approval_wait(agent_id: agent, execution_id: child)
        return {"status" => "no_matching_approval"} unless wait && wait.approval_request_id == input.fetch("approval")
        @agent.answer(agent, {"execution" => child, "approval" => wait.approval_request_id, "approved" => approved})
      when "deliver"
        observed = @stores.agent.observe_execution(agent_id: agent, execution_id: child)
        event = {completed: :child_completed, rejected: :child_rejected}[observed.status]
        return {"status" => "not_completed"} unless event
        output = observed.result if observed.status == :completed
        state = @workflow.send_saved_event(workflow_instance_id: parent, expected_revision: revision,
          event: event, input: {output: output, child_outcome: observed.status.to_s, consumed_revision: revision})
        {"status" => "applied", "outcome" => state.child_outcome, "output" => state.output}
      else
        raise ArgumentError, "Unsupported input"
      end
    end

    private

    def open_parent(parent, input)
      # This definition has one child slot per Workflow instance. Only the host
      # allocates IDs in this namespace, making the identity stable on redelivery.
      child = "workflow-child-v1:#{parent}"
      return {"status" => "wrong_child"} if input.key?("child") && input.fetch("child") != child
      agent = input.fetch("agent")
      text = input.fetch("text")
      unless @stores.workflow.load(parent)
        @workflow.invoke({agent_id: agent, child_id: child, text: text}, config: {workflow_instance_id: parent})
      end
      record = @stores.workflow.load(parent)
      fields = record.fetch(:snapshot).fetch("fields")
      raise ArgumentError, "Conflicting original input" unless fields.values_at("agent_id", "child_id", "text") == [agent, child, text]
      {"child" => child, "revision" => fields["consumed_revision"] || record.fetch(:revision)}
    end
  end
end
