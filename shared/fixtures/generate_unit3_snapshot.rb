# frozen_string_literal: true

# Fixture provenance: execute with UNIT3_CORE and UNIT3_EXAMPLES pointing to
# unmodified r8-unit3 checkouts. The test suite consumes the checked-in export.
$LOAD_PATH.unshift(File.join(ENV.fetch("UNIT3_CORE"), "lib"))
require "phronomy"
require "active_record"
require "tmpdir"
require "json"
require File.join(ENV.fetch("UNIT3_EXAMPLES"), "30_sqlite_persistence/db/schema")
legacy_mappings = PhronomyExamples::Persistence::StorageMapping.mappings
require_relative "../unit4_snapshot"
PhronomyExamples::Persistence::StorageMapping.define_singleton_method(:mappings) { legacy_mappings }

class LegacyFixtureRecord < ActiveRecord::Base
  self.abstract_class = true
end

Dir.mktmpdir do |dir|
  LegacyFixtureRecord.establish_connection(adapter: "sqlite3", database: File.join(dir, "source.sqlite3"))
  pool = LegacyFixtureRecord.connection_pool
  PhronomyExamples::Persistence::SQLiteSchema.apply!(pool)
  stores = Phronomy::PersistenceComposition.build(backend: PhronomyExamples::Persistence::ActiveRecordSQLite.new(connection_pool: pool))
  agent_store = stores.agent
  roots = %w[ordinary parent child source target unresolved].to_h do |id|
    root = Phronomy::Agent::AgentRoot.create(agent_id: id, agent_definition_id: "migration-agent", agent_definition_version: 1)
    agent_store.agents.create(root)
    [id, root]
  end
  %w[ordinary child].each do |id|
    root = roots.fetch(id)
    rows = ["first fact", "second fact"].each_with_index.map do |content, index|
      Phronomy::Agent::JournalRecord.new(agent_id: id, kind: :knowledge, channel: :context, role: :user,
        content_ref: agent_store.contents.put_text(content), context_candidate: true,
        metadata: {"source" => "original", "position" => index + 1})
    end
    agent_store.journals.append(id, expected_position: 0, records: rows)
    updated = root.with(agent_revision: 1, journal_position: 2, context_revision: 1)
    agent_store.agents.save(id, expected_revision: 0, root: updated)
    roots[id] = updated
  end
  make_execution = lambda do |id, status, metadata = {}, result = nil|
    root = roots.fetch(id)
    input = Phronomy::Agent::JournalRecord.new(agent_id: id, execution_id: "#{id}-run", kind: :input_received,
      channel: :external, role: :user, content_ref: agent_store.contents.put_text("input for #{id}"), context_candidate: false)
    initial = Phronomy::Agent::AgentExecution.start(agent_root: root, input_record: input, execution_id: "#{id}-run").with(execution_revision: 0, status: :active, phase: :calling_llm)
    agent_store.executions.create_active(initial)
    value = initial.with(status: status, phase: (status == :active) ? :calling_llm : status,
      metadata: metadata, result_ref: result && agent_store.contents.put_text(result))
    agent_store.executions.save(value.execution_id, expected_revision: 0, execution: value)
    value
  end
  make_execution.call("ordinary", :completed, {}, "saved ordinary result")
  child = make_execution.call("child", :completed, {"coordination" => {"kind" => "subagent", "parent_agent_id" => "parent", "parent_execution_id" => "parent-run", "slot" => "old-slot"}}, "saved child result")
  knowledge = [{"content" => "first fact", "metadata" => {"source" => "original", "position" => 1}},
    {"content" => "second fact", "metadata" => {"source" => "original", "position" => 2}}]
  children = [
    {"slot" => "old-slot", "name" => "research", "definition" => {"id" => "migration-agent", "version" => 1},
     "agent_id" => "child", "execution_id" => "child-run", "input_ref" => agent_store.contents.put_text("child input"),
     "knowledge_ref" => agent_store.contents.put_json(knowledge), "durable_context_ref" => nil,
     "state" => "completed", "result_ref" => child.result_ref, "error_ref" => nil, "on_error" => "raise"},
    {"slot" => "unstarted-slot", "name" => "research", "definition" => {"id" => "migration-agent", "version" => 1},
     "agent_id" => "old-reserved-agent-uuid", "execution_id" => "old-reserved-execution-uuid", "input_ref" => agent_store.contents.put_text("unstarted input"),
     "knowledge_ref" => agent_store.contents.put_json([]), "durable_context_ref" => nil,
     "state" => "reserved", "result_ref" => nil, "error_ref" => nil, "on_error" => "raise"}
  ]
  make_execution.call("parent", :active, {"multi_agent_coordination_ref" => agent_store.contents.put_json("kind" => "static_subagent", "children" => children), "coordination_cancel_requested" => true})
  context = Phronomy::Agent::HandoffContext.new(responsibility: "Preserve this exact responsibility", items: [])
  context_ref = agent_store.contents.put_json(context.to_h)
  owner = {"kind" => "handoff", "main_agent_id" => "source", "handoff_revision" => 2}
  make_execution.call("source", :handed_off, {"coordination" => owner, "handoff_target_agent_id" => "target",
    "handoff_target_execution_id" => "target-run", "handoff_context_ref" => context_ref})
  make_execution.call("target", :active, {"coordination" => owner, "durable_context_ref" => context_ref,
    "pending_llm_call_id" => "old-target-call"})
  make_execution.call("unresolved", :active, {"pending_llm_call_id" => "old-external-call", "pending_llm_started_at" => "2026-09-30T12:00:00Z"})
  now = "2026-09-30T12:00:00Z"
  routing = Phronomy::Agent::HandoffState.new(main_agent_id: "source", handoff_revision: 2,
    active_agent_id: "target", active_handoff_context_ref: context_ref, phase: "target_active",
    pending_source_execution_id: "source-run", pending_target_execution_id: "target-run",
    created_at: now, updated_at: now, metadata: {"cancelled_execution_ids" => ["target-run"],
                                                 "target_definition" => {"id" => "migration-agent", "version" => 1}})
  # Initial inserts accept revision 1; advance by CAS to preserve a real history.
  first = Phronomy::Agent::HandoffState.from_h(routing.to_h.merge("handoff_revision" => 1))
  agent_store.handoff_states.save("source", expected_revision: nil, state: first)
  agent_store.handoff_states.save("source", expected_revision: 1, state: routing)
  snapshot = PhronomyExamples::Persistence::Unit4Snapshot.export(pool, revision: "r8-unit3")
  File.write(ARGV.fetch(0), JSON.pretty_generate(snapshot) + "\n")
ensure
  pool&.disconnect!
end
