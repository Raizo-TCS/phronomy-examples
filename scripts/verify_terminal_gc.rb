# frozen_string_literal: true

require "tmpdir"
require "timeout"
require "json"
require "weakref"
require "digest"
require "sqlite3"
example = File.join(ENV.fetch("PHRONOMY_EXAMPLES"), "36_native_child_approval")
require File.join(example, "agents")
require File.join(example, "provider_fixture")

# Hash logical rows of every application table through an independent read-only
# connection, including BLOB content, journals, executions and retentions.
def contents_digest(path)
  db = SQLite3::Database.new(path, readonly: true)
  schema = db.execute("SELECT name, sql FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
  digest = Digest::SHA256.new
  digest << Marshal.dump(schema)
  schema.each do |name, _|
    raise "Unexpected application table name" unless name.match?(/\A[A-Za-z0-9_]+\z/)
    rows = db.execute(%(SELECT * FROM "#{name}"))
    rows.map { |row| Marshal.dump(row) }.sort.each { |row| digest << row }
  end
  digest.hexdigest
ensure
  db&.close
end

def terminal_owners(stores, mode, index, dbpath)
  events = Queue.new
  listener = ->(event) { events << event.payload.fetch(:request) if event.type == :approval_required }
  agent = NativeChild::Parent.create(agent_id: "weak-parent-#{index}", persistence: stores.agent, coordination_store: stores.multi_agent, on_event: listener)
  execution = "terminal-test-#{index}"
  reserved = Phronomy::Agent::ReservedExecution.new(agent_id: agent.agent_id, execution_id: execution)
  task = agent.start_hosted(reservation: reserved, input: "use the child")
  request = Timeout.timeout(12) { events.pop }
  begin
    task.wait_result(timeout: 12)
    raise "Parent unexpectedly completed before child"
  rescue Phronomy::ExecutionRehydrationRequiredError
    # Local parent is now idle, while its child is still suspended.
  end
  identity = stores.agent.execution_identity(request.execution_id)
  child = NativeChild::Child.get(identity.agent_id)
  raise unless child.approve(request.execution_id, approval_request_id: request.id).fetch(:output) == "child finished"
  raise unless agent.resume(execution).fetch(:output) == "received: child finished"
  refs = [WeakRef.new(agent), WeakRef.new(child)]
  parent = agent.agent_id
  before = contents_digest(dbpath)
  if mode == "generic"
    [agent, child].each do |a|
      begin
        a.unload!
        raise "Expected generic unload to refuse a retained owner"
      rescue Phronomy::AgentBusyError
        # An idle but retained owner is still in the live registry.
      end
    end
  elsif mode == "forget-control"
    stores.multi_agent.forget_subagents(agent_id: parent, execution_id: execution)
    raise unless agent.unload! && child.unload!
  elsif mode == "preserve"
    raise unless agent.unload_with_completed_child!(execution, execution_id: request.execution_id)
  else
    raise "unknown probe mode"
  end
  after = contents_digest(dbpath)
  raise "Logical DB digest unexpected" if (before == after) == (mode == "forget-control")
  [refs, [parent, identity.agent_id], [execution, request.execution_id], before, after, agent.__execution_environment.registry]
end

def advance_event_loop(registry)
  completion = Phronomy::TaskResult.deferred
  command = Struct.new(:coordinator)
  receiver = Object.new
  receiver.define_singleton_method(:deliver_on_event_loop) { |_item| completion.complete(true) }
  raise unless registry.post(command.new(receiver), completion: completion)
  completion.wait_result(timeout: 3)
end

Dir.mktmpdir do |directory|
  ENV["APPROVED_EFFECT_LOG"] = File.join(directory, "effects")
  dbpath = File.join(directory, "agents.sqlite3")
  stores = WorkerApproval.stores(dbpath, install: true)
  provider = NativeChild.fixed_provider
  mode = ARGV.fetch(0)
  runs = Integer(ENV.fetch("RECORDS","1"))
  records = (1..runs).map { |index| Thread.new { terminal_owners(stores, mode, index, dbpath) }.value }
  registry = records.last.last
  # Clear the last delivered command as in the standalone lifetime regression.
  advance_event_loop(registry)
  3.times { GC.start(full_mark: true, immediate_sweep: true) }
  initial = records.map { |entry| entry.first.map { |ref| !!ref.weakref_alive? } }
  if ENV["MORE_WORK"] == "1"
    3.times do |index|
      Thread.new do
        other = WorkerApproval::Conversation.create(agent_id: "fresh-#{index}", persistence: stores.agent)
        raise unless other.invoke("independent follow-up").fetch(:output) == "other job finished"
        raise unless other.unload!
      end.value
    end
    advance_event_loop(registry)
    3.times { GC.start(full_mark: true, immediate_sweep: true) }
  end
  results = records.map do |refs, ids, executions, before, after, _|
    live = refs.map { |ref| !!ref.weakref_alive? }
    registered = [NativeChild::Parent, NativeChild::Child].zip(ids).map { |type, id| !type.get(id).nil? }
    states = ids.zip(executions).map { |aid, id| stores.agent.observe_execution(agent_id: aid, execution_id: id).status }
    retentions = ids.map { |aid| stores.agent.retained_references(agent_id: aid).map(&:owner_key) }
    raise "Lost terminal records" unless states == [:completed, :completed]
    raise "Unexpected retention evidence" unless retentions.all? { |values| (mode == "forget-control") ? values.empty? : values == ["subagent:#{executions.first}"] }
    expected = [mode == "generic", mode == "generic"]
    raise "Wrong registry state" unless registered == expected
    {ids: ids, executions: executions, registered: registered, reachable: live, states: states, retentions: retentions, durable_rows_before: before, durable_rows_after: after}
  end
  result = {mode: mode, prior_to_other_work: initial, records: results, provider_calls: provider.calls.size,
            effects: File.readlines(ENV.fetch("APPROVED_EFFECT_LOG"), chomp: true)}
  puts JSON.generate(result)
  raise "Unexpected Tool count" unless result[:effects].size == runs
  expected_calls = 4 * runs + ((ENV["MORE_WORK"] == "1") ? 3 : 0)
  raise "Unexpected provider calls" unless provider.calls.size == expected_calls
  if ENV["MORE_WORK"] == "1"
    retained = results.map { |record| record[:reachable] }
    case mode
    when "generic" then raise unless retained.all? { |v| v == [true,true] }
    else raise "Old owners retained after independent work" if retained.flatten.any?(true)
    end
  end
ensure
  WorkerApproval::Record.connection_pool.disconnect! if WorkerApproval::Record.connected?
end
