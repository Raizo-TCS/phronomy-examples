# frozen_string_literal: true

require "json"
require_relative "../../../36_native_child_approval/handler"
require_relative "../../../36_native_child_approval/provider_fixture"

# Keep the example's agent definitions and default error policies. Only the
# external I/O behind the approved Tool is replaced with a deterministic fault.
module FailingChange
  def execute
    File.open(ENV.fetch("APPROVED_EFFECT_LOG"), "a") { |log| log.puts(Process.pid) }
    raise IOError, "injected write failure"
  end
end
WorkerApproval::ApplyRequest.prepend(FailingChange)

class FailureHandler < NativeChild::Handler
  def answer_and_import
    approve = observe do
      @child.approve(@ticket.fetch("child_execution"), approval_request_id: @ticket.fetch("approval"))
    end
    import = observe { @parent.resume(@ticket.fetch("execution")) }
    {"approval" => approve, "import" => import, "calls" => @provider.calls.size}
  end

  def read_results(ticket)
    @parent ||= NativeChild::Parent.load(ticket.fetch("parent"), persistence: @store, coordination_store: @coordination)
    @child ||= NativeChild::Child.load(ticket.fetch("child"), persistence: @store)
    calls = @provider.calls.size
    outcomes = [[@parent, ticket.fetch("execution")], [@child, ticket.fetch("child_execution")]].map do |agent, execution|
      state = @store.observe_execution(agent_id: agent.agent_id, execution_id: execution)
      [state.status.to_s, observe { agent.resume(execution) }]
    end
    {"outcomes" => outcomes, "calls" => @provider.calls.size - calls}
  end

  def release_failed_pair(ticket)
    release_completed(ticket)
  rescue Phronomy::AgentBusyError => error
    {"released" => false, "reason" => error.message}
  end

  def fresh_turn
    stub = ExampleChatStub.new do |body, _|
      raise "unexpected provider request" unless body.fetch("messages").last.fetch("content") == "new independent question"
      "new turn completed"
    end
    result = @parent.invoke("new independent question")
    {"id" => result.fetch(:execution_id), "output" => result.fetch(:output), "calls" => stub.calls.size}
  end

  private

  def observe
    answer = yield
    {"status" => answer[:status], "output" => answer[:output]}
  rescue Phronomy::Error => error
    {"error_class" => error.class.name, "error" => error.message}
  end
end

handler = FailureHandler.new(WorkerApproval.stores(ARGV.fetch(0)), NativeChild.fixed_provider)
STDOUT.sync = true
STDIN.each_line do |line|
  job = JSON.parse(line)
  result = case job.fetch("op")
  when "start" then handler.start("use the child")
  when "restore" then handler.restore(job.fetch("ticket"))
  when "fail" then handler.answer_and_import
  when "read" then handler.read_results(job.fetch("ticket"))
  when "release" then handler.release_failed_pair(job.fetch("ticket"))
  when "next" then handler.fresh_turn
  else raise ArgumentError, "unsupported command"
  end
  puts JSON.generate(result)
end
