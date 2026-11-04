# frozen_string_literal: true

require "bundler/setup"
require "json"
require "rbconfig"
require "securerandom"
require "timeout"
require "tmpdir"

module CrashProbe
  module_function

  def check(condition, message)
    raise "Verification failed: #{message}" unless condition
  end

  def emit(**fields)
    puts JSON.generate(fields)
    $stdout.flush
  end

  def assert_receipt(dir, request_id)
    receipts = File.readlines(File.join(dir, "effects.jsonl"), chomp: true).map { |line| JSON.parse(line) }
    check(receipts.size == 1, "expected exactly one external effect, got #{receipts.size}")
    receipt = receipts.fetch(0)
    check(receipt.fetch("request_id") == request_id, "wrong business operation")
    receipt
  end

  def launch(role, *args)
    rd, wr = IO.pipe
    pid = Process.spawn(RbConfig.ruby, __FILE__, role, *args, out: wr)
    wr.close
    yield pid, rd
  ensure
    wr&.close unless wr&.closed?
    rd&.close
    if pid
      begin
        if Process.waitpid(pid, Process::WNOHANG).nil?
          Process.kill("KILL", pid)
          Process.waitpid(pid)
        end
      rescue Errno::ECHILD
        # The caller already checked this child's exit status.
      end
    end
  end

  def run
    Dir.mktmpdir("tool-effect-crash-") do |dir|
      ids = [SecureRandom.uuid, SecureRandom.uuid]
      worker_a = nil
      launch("dispatch", dir, *ids) do |pid, events|
        worker_a = pid
        line = Timeout.timeout(30) { events.gets }
        check(line && JSON.parse(line) == {"effect_written" => ids.last, "pid" => pid}, "missing effect barrier")
        check(assert_receipt(dir, ids.last).fetch("pid") == pid, "wrong effect writer")
        Process.kill("KILL", pid)
        _, status = Process.wait2(pid)
        check(status.signaled? && status.termsig == Signal.list.fetch("KILL"), "Worker A was not killed")
      end
      launch("recover", dir, *ids) do |pid, events|
        line, status = Timeout.timeout(90) { [events.read, Process.wait2(pid).last] }
        check(status.success?, "recovery worker failed")
        report = JSON.parse(line)
        check(report.fetch("pid") == pid && pid != worker_a, "invalid process handoff")
        assert_receipt(dir, ids.last)
        emit(scenario: "tool_effect_before_result_commit", worker_a: worker_a, killed: "SIGKILL",
          worker_b: pid, execution_id: ids.first, receipts: 1, recovery: report)
      end
    end
  end
end

case ARGV.first
when nil
  CrashProbe.run
  exit
when "dispatch", "recover"
  raise ArgumentError, "expected role, directory, execution ID and request ID" unless ARGV.size == 4
else
  raise ArgumentError, "unsupported worker role: #{ARGV.first.inspect}"
end

require_relative "../../34_worker_approval/conversation"
require_relative "../support/chat_stub"
require "webmock"

class WriteExternalReceipt < Phronomy::Tool::Base
  tool_name "write_external_receipt"
  description "Write one external business receipt."
  param :request_id, type: :string, desc: "Business request identifier", required: true

  def execute(request_id:)
    dir = ENV.fetch("CRASH_PROBE_DIR")
    receipt = {request_id: request_id, result: "applied-#{request_id}", pid: Process.pid}
    File.open(File.join(dir, "effects.jsonl"), "a") do |f|
      f.puts JSON.generate(receipt)
      f.fsync
    end
    CrashProbe.emit(effect_written: request_id, pid: Process.pid)
    sleep # Supervisor kills the worker before the Tool can return a result.
  end
end

class ReceiptAgent < Phronomy::Agent::Base
  agent_definition id: "tool-effect-crash-probe", version: 1
  model "gpt-4o-mini"
  provider :openai
  tools WriteExternalReceipt => nil
end

role, dir, execution_id, request_id = ARGV
ENV["CRASH_PROBE_DIR"] = dir
WebMock.enable!
WebMock.disable_net_connect!
RubyLLM.configure do |config|
  config.openai_protocol = :chat_completions
  config.openai_api_base = "https://example.test/v1"
  config.openai_api_key = "offline"
end

stub = ExampleChatStub.new do |body, index|
  raise "Unexpected additional provider request" unless index.zero?
  if role == "dispatch"
    ExampleChatStub.tool("write_external_receipt", {request_id: request_id})
  else
    msg = body.fetch("messages").last
    CrashProbe.check(msg.fetch("role") == "tool" && msg.fetch("content") == "applied-#{request_id}",
      "provider did not receive the independently reconciled result")
    "receipt confirmed"
  end
end

store = WorkerApproval.store(File.join(dir, "store.sqlite3"), install: role == "dispatch")
if role == "dispatch"
  agent = ReceiptAgent.create(agent_id: "receipt-agent", persistence: store)
  reservation = Phronomy::Agent::ReservedExecution.new(agent_id: agent.agent_id, execution_id: execution_id)
  agent.start_hosted(reservation: reservation, input: "Apply request #{request_id}").wait_result(timeout: 30)
  raise "Dispatch returned before the kill barrier"
end

events = Queue.new
agent = ReceiptAgent.load("receipt-agent", persistence: store, on_event: lambda { |event|
  events << event.payload if event.type == :recovery_resolution_required
})
event = Timeout.timeout(12) { events.pop }
subject = event.fetch(:subject)
facts = event.fetch(:facts)
CrashProbe.check(event.fetch(:execution_id) == execution_id && event.fetch(:reason) == :outcome_unknown &&
  subject.fetch(:type) == :tool_invocation && !subject.fetch(:tool_invocation_id).empty?, "incorrect recovery subject")
CrashProbe.check(facts.fetch(:tool_name) == "write_external_receipt" &&
  facts.fetch(:arguments).fetch("request_id") == request_id, "wrong Tool or business request")
CrashProbe.check(stub.calls.empty?, "provider was called before external reconciliation")
receipt = CrashProbe.assert_receipt(dir, request_id)
resolution = agent.resolve_async(execution_id, expected_execution_revision: event.fetch(:execution_revision),
  subject: subject, outcome: :succeeded, result: receipt.fetch("result"))
begin
  result = resolution.wait_result(timeout: 65)
rescue Phronomy::TimeoutError
  run = store.executions.load(execution_id)
  warn JSON.generate(revision: run.execution_revision, status: run.status, phase: run.phase,
    provider_calls: stub.calls.size, external_receipts: File.readlines(File.join(dir, "effects.jsonl")).size)
  Thread.list.each do |thread|
    warn "Thread #{thread.name.inspect} #{thread.status}"
    warn Array(thread.backtrace).first(12).join("\n")
  end
  raise
end
CrashProbe.check(result.fetch(:output) == "receipt confirmed" && result.fetch(:execution_id) == execution_id &&
  stub.calls.size == 1, "reconciled execution did not complete")
run = store.executions.load(execution_id)
CrashProbe.check(run.status == :completed, "execution terminal status was #{run.status}")
agent.unload!
CrashProbe.emit(pid: Process.pid, reason: event.fetch(:reason), subject: subject, output: result.fetch(:output),
  status: run.status, provider_calls: stub.calls.size)
