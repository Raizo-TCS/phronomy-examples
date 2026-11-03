# frozen_string_literal: true

require "timeout"
require_relative "agents"

module NativeChild
  class Handler
    def initialize(stores, provider)
      @store = stores.agent
      @coordination = stores.multi_agent
      @provider = provider
    end

    # A starts two independent Executions. Only the parent and its native child move.
    def start
      other_events = Queue.new
      @other = WorkerApproval::Conversation.create(agent_id: "other", persistence: @store, on_event: listener(other_events))
      @other_task = @other.start_hosted(reservation: reserve(@other, "other-execution"), input: "other gated job")
      @other_request = Timeout.timeout(12) { other_events.pop }

      events = Queue.new
      @parent = Parent.create(agent_id: "parent", persistence: @store, coordination_store: @coordination, on_event: listener(events))
      reservation = reserve(@parent, "parent-execution")
      hosted = @parent.start_hosted(reservation: reservation, input: "use the child")
      request = Timeout.timeout(12) { events.pop }
      identity = @store.execution_identity(request.execution_id)
      @child = WorkerApproval::Conversation.get(identity.agent_id)
      NativeChild.check(identity.correlation.values_at("parent_agent_id", "parent_execution_id"), [reservation.agent_id, reservation.execution_id])
      wait = hosted.detach!(execution_id: request.execution_id, approval_request_id: request.id)
      NativeChild.check([wait.execution_id, wait.approval_request_id], [request.execution_id, request.id])
      NativeChild.check(Parent.get("parent"), nil)
      NativeChild.check(WorkerApproval::Conversation.get(identity.agent_id), nil)
      NativeChild.check(@provider.calls.length, 3)
      @ticket = {"parent" => reservation.agent_id, "execution" => reservation.execution_id, "child" => identity.agent_id,
                 "child_execution" => request.execution_id, "approval" => request.id}
    end

    # B reconstructs the exact pair from durable state, then waits for the host's decision.
    def restore(ticket)
      events = Queue.new
      @parent = Parent.load(ticket.fetch("parent"), persistence: @store, coordination_store: @coordination, on_event: listener(events))
      parent_id = ticket.fetch("execution")
      identity = @store.execution_identity(ticket.fetch("child_execution"))
      NativeChild.check([identity.agent_id, *identity.correlation.values_at("parent_agent_id", "parent_execution_id")],
        ticket.values_at("child", "parent", "execution"))
      waiting = @parent.resume_async(parent_id)
      request = Timeout.timeout(12) { events.pop }
      NativeChild.check([request.execution_id, request.id], ticket.values_at("child_execution", "approval"))
      begin
        waiting.wait_result(timeout: 12)
        raise "Expected the durable parent to remain unfinished"
      rescue Phronomy::ExecutionRehydrationRequiredError
        # The native parent can resume after the child has a durable result.
      end
      @child = WorkerApproval::Conversation.get(identity.agent_id)
      @ticket = ticket
      NativeChild.check(@provider.calls.length, 0)
      {"restored" => ticket}
    end

    # A's old instances cannot act, although the unrelated live instance still can.
    def other_work
      assert_unloaded { @parent.resume(@ticket.fetch("execution")) }
      assert_unloaded { @child.approve(@ticket.fetch("child_execution"), approval_request_id: @ticket.fetch("approval")) }
      NativeChild.check(WorkerApproval::Conversation.get("other").equal?(@other), true)
      rejected = @other.approve(@other_request.execution_id, approval_request_id: @other_request.id, approved: false)
      NativeChild.check(rejected.fetch(:rejected), true)
      NativeChild.check(@other_task.wait_result(timeout: 12).fetch(:rejected), true)
      result = @other.invoke("independent follow-up")
      @other.unload!
      NativeChild.check(@provider.calls.length, 4)
      {"other" => result.fetch(:output)}
    end

    def answer(approved)
      child_id = @ticket.fetch("child_execution")
      result = @child.approve(child_id, approval_request_id: @ticket.fetch("approval"), approved: approved)
      NativeChild.check(result.fetch(:execution_id), child_id)
      NativeChild.check(approved ? result.fetch(:output) : result.fetch(:rejected), approved ? "child finished" : true)
      id = @ticket.fetch("execution")
      completed = @parent.resume(id)
      NativeChild.check(completed.values_at(:execution_id, :output), [id, approved ? "received: child finished" : "no child output"])
      NativeChild.check(@parent.resume(id), completed)
      NativeChild.check(@provider.calls.length, approved ? 2 : 1)
      {"child" => @store.observe_execution(agent_id: @ticket.fetch("child"), execution_id: child_id).status.to_s,
       "parent" => @store.observe_execution(agent_id: @ticket.fetch("parent"), execution_id: id).status.to_s}
    end

    private

    def reserve(agent, id)
      Phronomy::Agent::ReservedExecution.new(agent_id: agent.agent_id, execution_id: id)
    end

    def listener(queue)
      ->(event) { queue << event.payload.fetch(:request) if event.type == :approval_required }
    end

    def assert_unloaded
      yield
      raise "Detached instance accepted an operation"
    rescue Phronomy::AgentUnloadedError
      # The host retains these references only to exercise the stale-operation guard.
    end
  end
end
