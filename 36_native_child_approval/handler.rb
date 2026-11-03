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
    def start(input)
      other_events = Queue.new
      @other = WorkerApproval::Conversation.create(agent_id: "other", persistence: @store, on_event: listener(other_events))
      @other_task = @other.start_hosted(reservation: reserve(@other, "other-execution"), input: "other gated job")
      @other_request = Timeout.timeout(12) { other_events.pop }

      events = Queue.new
      @parent = Parent.create(agent_id: "parent", persistence: @store, coordination_store: @coordination, on_event: listener(events))
      reservation = reserve(@parent, "parent-execution")
      hosted = @parent.start_hosted(reservation: reservation, input: input)
      request = Timeout.timeout(12) { events.pop }
      NativeChild.check(request.items.map(&:tool_name), ["apply_request"])
      identity = @store.execution_identity(request.execution_id)
      @child = Child.get(identity.agent_id)
      NativeChild.check(identity.correlation.values_at("parent_agent_id", "parent_execution_id"), [reservation.agent_id, reservation.execution_id])
      detach(hosted, request)
      NativeChild.check(@provider.calls.length, 3)
      @ticket = {"parent" => reservation.agent_id, "execution" => reservation.execution_id, "child" => identity.agent_id,
                 "child_execution" => request.execution_id, "approval" => request.id}
    end

    # Each receiving worker reopens the exact saved wait before accepting a decision.
    def restore(ticket)
      @events = Queue.new
      @parent = Parent.load(ticket.fetch("parent"), persistence: @store, coordination_store: @coordination, on_event: listener(@events))
      parent_id = ticket.fetch("execution")
      identity = @store.execution_identity(ticket.fetch("child_execution"))
      NativeChild.check([identity.agent_id, *identity.correlation.values_at("parent_agent_id", "parent_execution_id")],
        ticket.values_at("child", "parent", "execution"))
      waiting = @parent.resume_async(parent_id)
      request = Timeout.timeout(12) { @events.pop }
      NativeChild.check([request.execution_id, request.id], ticket.values_at("child_execution", "approval"))
      begin
        waiting.wait_result(timeout: 12)
        raise "Expected the durable parent to remain unfinished"
      rescue Phronomy::ExecutionRehydrationRequiredError
        # The native parent can resume after the child has a durable result.
      end
      @child = Child.get(identity.agent_id)
      @ticket = ticket
      NativeChild.check(@provider.calls.length, 0)
      {"restored" => ticket}
    end

    def approve_and_handoff
      answer = @parent.approve_hosted_child(@ticket.fetch("execution"), execution_id: @ticket.fetch("child_execution"),
        approval_request_id: @ticket.fetch("approval"))
      next_request = Timeout.timeout(12) { @events.pop }
      NativeChild.check(next_request.execution_id, @ticket.fetch("child_execution"))
      NativeChild.check(next_request.items.map(&:tool_name), ["publish_request"])
      raise "Expected a new approval request" if next_request.id == @ticket.fetch("approval")

      begin
        answer.detach!(execution_id: next_request.execution_id, approval_request_id: @ticket.fetch("approval"))
        raise "The consumed approval released a newer wait"
      rescue Phronomy::AgentBusyError
        # Only the new request permits releasing this wait.
      end
      wait = detach(answer, next_request)
      NativeChild.check(answer.wait_result(timeout: 12), wait)
      NativeChild.check(@provider.calls.length, 1)
      @ticket = @ticket.merge("approval" => next_request.id)
    end

    # Each released worker can do independent work while its successor owns the pair.
    def other_work
      assert_unloaded { @parent.resume(@ticket.fetch("execution")) }
      assert_unloaded { @child.approve(@ticket.fetch("child_execution"), approval_request_id: @ticket.fetch("approval")) }
      before = @provider.calls.length
      if @other
        NativeChild.check(WorkerApproval::Conversation.get("other").equal?(@other), true)
        rejected = @other.approve(@other_request.execution_id, approval_request_id: @other_request.id, approved: false)
        NativeChild.check(rejected.fetch(:rejected), true)
        NativeChild.check(@other_task.wait_result(timeout: 12).fetch(:rejected), true)
      else
        @other = WorkerApproval::Conversation.create(persistence: @store)
      end
      result = @other.invoke("independent follow-up")
      @other.unload!
      NativeChild.check(@provider.calls.length, before + 1)
      {"other" => result.fetch(:output)}
    end

    def replay_approval(id)
      @parent.approve_hosted_child(@ticket.fetch("execution"), execution_id: @ticket.fetch("child_execution"),
        approval_request_id: id)
      raise "Accepted an already consumed approval request"
    rescue Phronomy::AgentBusyError
      {"refused" => id}
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

    # Each worker reads the terminal history from its own SQLite connection.
    def terminal_history(ids)
      before = @provider.calls.length
      @parent ||= Parent.load(ids.fetch("parent"), persistence: @store, coordination_store: @coordination)
      @child ||= Child.load(ids.fetch("child"), persistence: @store)
      history = [[@parent, ids.fetch("execution")], [@child, ids.fetch("child_execution")]].map do |agent, id|
        result = agent.resume(id)
        holds = @store.retained_references(agent_id: agent.agent_id)
        raise "Expected retained native history" if holds.empty?
        {"result" => result.slice(:execution_id, :status, :output),
         "transcript" => agent.transcript_messages.map(&:to_h), "retentions" => holds.map(&:to_h)}
      end
      NativeChild.check(@provider.calls.length, before)
      history
    end

    def release_completed(ids)
      released = @parent.unload_with_completed_child!(ids.fetch("execution"), execution_id: ids.fetch("child_execution"))
      NativeChild.check(Parent.get(@parent.agent_id), nil)
      NativeChild.check(Child.get(@child.agent_id), nil)
      {"released" => released}
    end

    def next_turn
      reply = @parent.invoke("recall the prior turn")
      NativeChild.check(@provider.calls.length, 1)
      {"output" => reply.fetch(:output)}
    end

    private

    def detach(hosted, request)
      wait = hosted.detach!(execution_id: request.execution_id, approval_request_id: request.id)
      NativeChild.check([wait.execution_id, wait.approval_request_id], [request.execution_id, request.id])
      NativeChild.check(Parent.get(@parent.agent_id), nil)
      NativeChild.check(Child.get(@child.agent_id), nil)
      wait
    end

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
