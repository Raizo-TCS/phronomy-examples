# frozen_string_literal: true

require "spec_helper"
require_relative "../../shared/unit4_snapshot"

RSpec.describe "Explicit unit 3 to unit 4 database migration" do
  let(:source) { JSON.parse(File.read(File.expand_path("../../shared/fixtures/unit3_snapshot.json", __dir__))) }
  let(:converted) { Phronomy::PersistenceComposition::Unit4Migration.convert(source, quiescent: true) }

  def import_snapshot(snapshot = converted)
    stores, pool, path = build_sqlite_persistence
    PhronomyExamples::Persistence::Unit4Snapshot.import(snapshot, backend: stores.coordinator.backend, connection_pool: pool)
    # A separate pool is required: a transaction's cached values prove nothing.
    reloaded, fresh_pool, = build_sqlite_persistence(database_path: path)
    expect(PhronomyExamples::Persistence::Unit4Snapshot.verify(snapshot, connection_pool: fresh_pool)).to be(true)
    [reloaded, fresh_pool]
  end

  after { Phronomy.reset_runtime! }

  it "preserves existing IDs, physical revisions, logical revisions and terminal results" do
    stores, = import_snapshot
    original = source.fetch("resources").fetch("agent.executions").fetch("entries")
    original.each do |entry|
      value = stores.agent.executions.load(entry.fetch("key"))
      expect(value.execution_revision).to eq(entry.fetch("revision"))
      expect(value.agent_id).to eq(entry.fetch("record").fetch("payload").fetch("agent_id"))
    end
    klass = Class.new(Phronomy::Agent::Base) { agent_definition id: "migration-agent", version: 1 }
    restored = klass.load("ordinary", persistence: stores.agent)
    expect(restored.resume("ordinary-run").fetch(:output)).to eq("saved ordinary result")
  end

  it "preserves old reserved identities, knowledge order/metadata and parent cancellation" do
    stores, = import_snapshot
    extension = stores.agent.execution_extension(agent_id: "parent", execution_id: "parent-run", binding_key: "phronomy.subagent")
    children = stores.multi_agent.contents.fetch_json(extension.state_ref).fetch("children")
    expect(children.map { |child| child.fetch("execution_id") }).to eq(%w[child-run old-reserved-execution-uuid])
    expect(children.first.fetch("knowledge")).to eq([
      {"content" => "first fact", "metadata" => {"source" => "original", "position" => 1}},
      {"content" => "second fact", "metadata" => {"source" => "original", "position" => 2}}
    ])
    parent = stores.agent.observe_execution(agent_id: "parent", execution_id: "parent-run")
    expect(parent).to be_active
    expect(parent.cancellation_requested).to be(true)
    expect(stores.agent.retained_references(agent_id: "child").map(&:owner_key)).to include("subagent:parent-run")
  end

  it "preserves transfer content, routing, target cancellation and unknown external work" do
    stores, = import_snapshot
    source_execution = stores.agent.observe_execution(agent_id: "source", execution_id: "source-run")
    context = stores.multi_agent.contents.fetch_json(source_execution.transfer_receipt.fetch("context_ref"))
    expect(context.fetch("responsibility")).to eq("Preserve this exact responsibility")
    expect(stores.multi_agent.handoff_states.load("source").handoff_revision).to eq(2)
    target = stores.agent.observe_execution(agent_id: "target", execution_id: "target-run")
    expect(target).to be_active
    expect(target.cancellation_requested).to be(true)
    unknown = stores.agent.observe_execution(agent_id: "unresolved", execution_id: "unresolved-run")
    expect(unknown).to be_active
    expect(unknown).not_to be_terminal
    expect(stores.agent.executions.load("unresolved-run").metadata.fetch("pending_llm_call_id")).to eq("old-external-call")
    expect(stores.agent.retained_references(agent_id: "source")).not_to be_empty
    expect(stores.agent.retained_references(agent_id: "target")).not_to be_empty
  end

  [:missing_blob, :wrong_owner, :wrong_revision, :broken_journal, :wrong_version].each do |corruption|
    it "aborts conversion for #{corruption} without changing its input" do
      snapshot = Marshal.load(Marshal.dump(source))
      resources = snapshot.fetch("resources")
      execution = resources.fetch("agent.executions").fetch("entries").first
      case corruption
      when :missing_blob then resources.fetch("content.blobs").fetch("entries").shift
      when :wrong_owner then execution.fetch("record").fetch("payload")["agent_id"] = "missing"
      when :wrong_revision then execution["revision"] += 1
      when :broken_journal then resources.fetch("agent.journal").fetch("heads")["ordinary"] = 9
      when :wrong_version then execution.fetch("record")["format_version"] = "99"
      end
      original = Marshal.load(Marshal.dump(snapshot))
      expect { Phronomy::PersistenceComposition::Unit4Migration.convert(snapshot, quiescent: true) }
        .to raise_error(Phronomy::Persistence::SerializationError)
      expect(snapshot).to eq(original)
    end
  end

  it "requires explicit writer quiescence and rejects runtime loading of 0.1 executions" do
    expect { Phronomy::PersistenceComposition::Unit4Migration.convert(source, quiescent: false) }.to raise_error(ArgumentError)
    entry = source.fetch("resources").fetch("agent.executions").fetch("entries").first.fetch("record")
    record = Phronomy::Storage::DurableRecord.new(**entry.transform_keys(&:to_sym))
    expect { Phronomy::Agent::Persistence::Codec.decode_agent_execution(record) }.to raise_error(Phronomy::Storage::SerializationError)
    routing = source.fetch("resources").fetch("handoff.states").fetch("entries").first.fetch("record")
    old_routing = Phronomy::Storage::DurableRecord.new(**routing.transform_keys(&:to_sym))
    expect { Phronomy::MultiAgent::Persistence::Codec.decode_handoff_state(old_routing) }.to raise_error(Phronomy::Storage::SerializationError)
  end

  it "refuses a populated destination without changing it" do
    stores, pool = import_snapshot
    expect { PhronomyExamples::Persistence::Unit4Snapshot.import(converted, backend: stores.coordinator.backend, connection_pool: pool) }
      .to raise_error(ArgumentError, /not empty/)
    expect(PhronomyExamples::Persistence::Unit4Snapshot.verify(converted, connection_pool: pool)).to be(true)
  end

  it "rolls the entire destination back when a later stream write is invalid" do
    stores, pool, = build_sqlite_persistence
    broken = Marshal.load(Marshal.dump(converted))
    broken.fetch("resources").fetch("agent.journal").fetch("heads")["ordinary"] = 1
    broken.fetch("migration")["resources_sha256"] = Digest::SHA256.hexdigest(Phronomy::CanonicalJSON.dump(broken.fetch("resources")))
    expect { PhronomyExamples::Persistence::Unit4Snapshot.import(broken, backend: stores.coordinator.backend, connection_pool: pool) }.to raise_error(ArgumentError)
    observed = PhronomyExamples::Persistence::Unit4Snapshot.export(pool, revision: "r8-unit4")
    expect(observed.fetch("resources").values.all? { |resource| resource.fetch("entries").empty? }).to be(true)
  end
end
