# frozen_string_literal: true

require "timeout"
require_relative "conversation"

module WorkerApproval
  class Handler
    def initialize(store)
      @store = store
    end

    def call(job)
      input = JSON.parse(job.fetch("body"))
      target = job.fetch("target")
      case input.fetch("kind")
      when "start"
        start(target, input)
      when "answer"
        answer(target, input)
      else
        raise ArgumentError, "unsupported input"
      end
    end

    def start(target, input)
      outcomes = Queue.new
      agent = Conversation.load(target, persistence: @store, on_event: ->(event) {
        outcomes << [:waiting, event.payload.fetch(:request), nil] if event.type == :approval_required
      })
      reservation = Phronomy::Agent::ReservedExecution.new(agent_id: target, execution_id: input.fetch("execution"))
      handle = agent.start_hosted(reservation: reservation, input: input.fetch("text"))
      handle.on_complete { |value, error| outcomes << [:finished, value, error] }
      kind, value, error = Timeout.timeout(12) { outcomes.pop }
      raise error if error
      if kind == :waiting
        wait = handle.detach!(approval_request_id: value.id)
        {"execution" => wait.execution_id, "approval" => wait.approval_request_id}
      else
        agent.unload!
        {"execution" => value.fetch(:execution_id), "output" => value.fetch(:output)}
      end
    end

    def answer(target, input)
      approvals = Queue.new
      agent = Conversation.load(target, persistence: @store, on_event: listener(approvals))
      request = Timeout.timeout(12) { approvals.pop }
      unless request.execution_id == input.fetch("execution") && request.id == input.fetch("approval")
        raise ArgumentError, "answer does not identify this approval"
      end
      result = agent.approve(request.execution_id, approval_request_id: request.id, approved: input.fetch("approved"))
      agent.unload!
      return {"execution" => result.fetch(:execution_id), "status" => "rejected"} if result[:rejected]
      {"execution" => result.fetch(:execution_id), "output" => result.fetch(:output)}
    end

    private

    def listener(queue)
      ->(event) { queue << event.payload.fetch(:request) if event.type == :approval_required }
    end
  end
end
