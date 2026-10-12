# frozen_string_literal: true

RSpec.shared_examples "persisted Agent scope lifetimes" do
  let(:store) { initial_storage.first.agent }
  let(:agent_class) do
    Class.new(Phronomy::Agent::Base) do
      agent_definition id: "dx05-sql-lifetime", version: 1
      model "local-model"
    end
  end

  after { Phronomy.reset_runtime! }

  def snapshot(store, agent_id)
    [store.agents.load(agent_id).to_h,
      store.journals.read(agent_id).map(&:to_h),
      store.runs(agent_id).map(&:to_h),
      store.knowledge_snapshot(agent_id: agent_id).map(&:to_h)]
  end

  it "preserves every saved revision/history field across unload and fresh-pool reload, with a new listener" do
    agent = agent_class.create(agent_id: "sql-lifetime", persistence: store, metadata: {"business" => "value"})
    agent.add_knowledge("remember", metadata: {"source" => "scope-test"})
    agent.clear_transcript!
    agent.close!
    saved = snapshot(store, agent.agent_id)
    expect(agent.unload!).to be(true)
    expect(snapshot(store, agent.agent_id)).to eq(saved)
    initial_storage.fetch(1).disconnect!
    reopened = reopened_storage
    listener = ->(_event) {}
    loaded = agent_class.load(agent.agent_id, persistence: reopened.first.agent, on_event: listener)
    expect(loaded).not_to equal(agent)
    expect(loaded.event_listener).to equal(listener)
    expect(loaded.agent_root.lifecycle_status).to eq(:closed)
    expect(snapshot(reopened.first.agent, loaded.agent_id)).to eq(saved)
    expect { agent.reset_context! }.to raise_error(Phronomy::AgentUnloadedError)
    expect(agent.unload!).to be(false)
    loaded.unload!
  end

  it "does not remove an opaque durable retention" do
    agent = agent_class.create(agent_id: "retained", persistence: store)
    retention = Phronomy::Agent::Retention.new(agent_id: agent.agent_id, owner_key: "external-domain")
    store.transaction { |tx| tx.retentions.retain(retention) }
    expect { agent.unload! }.to raise_error(Phronomy::AgentBusyError)
    expect(store.transaction { |tx| tx.retentions.list(agent.agent_id) }).to eq([retention])
    expect(agent_class.get(agent.agent_id)).to equal(agent)
  end

  it "restores the owner after a Store check fails, preserving the exact failure" do
    agent = agent_class.create(agent_id: "read-failure", persistence: store)
    error = IOError.new("unload read failed")
    allow(store).to receive(:transaction).and_raise(error)
    expect { agent.unload! }.to raise_error { |actual| expect(actual).to equal(error) }
    expect(agent_class.get(agent.agent_id)).to equal(agent)
    allow(store).to receive(:transaction).and_call_original
    expect(agent.unload!).to be(true)
  end

  it "cleans up asynchronous scope materialization while leaving the shared pool usable" do
    id = nil
    expect(Phronomy::Agent.open_scope { |scope|
      scope.create_async(agent_class, persistence: store).map { |agent| id = agent.agent_id; :done }
    }).to eq(:done)
    expect(agent_class.get(id)).to be_nil
    expect(store.agents.load(id).agent_id).to eq(id)
    expect(initial_storage.fetch(1).with_connection { |connection| connection.select_value("SELECT 1").to_i }).to eq(1)
  end
end
