# frozen_string_literal: true

require "spec_helper"
require "phronomy/active_record/schema_v1"

RSpec.describe "Optional ActiveRecord distribution" do
  it "composes stores without schema writes or closing the application pool" do
    _stores, pool = build_sqlite_persistence
    expect(pool).not_to receive(:disconnect!)
    pool.with_connection do |connection|
      expect(connection).not_to receive(:create_table)
      expect(connection).not_to receive(:add_index)
      expect(connection).not_to receive(:drop_table)
      stores = PhronomyActiveRecord.build(connection_pool: pool, dialect: :sqlite)
      root = build_agent_root
      stores.agent.agents.create(root)
      expect(stores.agent.agents.load(root.agent_id).to_h).to eq(root.to_h)
      expect(stores.multi_agent.agent_store).to equal(stores.agent)
    end
  end

  it "reads a database produced by the unchanged v0.28 reference implementation" do
    stores, pool = build_sqlite_persistence
    sql = File.read(File.join(__dir__, "fixtures/v0280_reference.sql"))
    pool.with_connection do |connection|
      connection.tables.grep(/^phronomy_/).each { |table| connection.drop_table(table) }
      connection.raw_connection.execute_batch(sql)
    end
    imported = PhronomyActiveRecord.build(connection_pool: pool, dialect: :sqlite)
    root = imported.agent.agents.load("dx02-existing-agent")
    expect(root.agent_id).to eq("dx02-existing-agent")
    expect(imported.agent.contents.fetch_text("sha256:0c2e77b0206cb65a01fa50b8f4068e090e47e1e935ac70497ac0e375c557f6bc"))
      .to eq("Existing reference backend content")
    # A new composition has the same physical mapping as the old store instance.
    expect(stores.agent.agents.load(root.agent_id).to_h).to eq(root.to_h)
  end

  it "installs the versioned schema explicitly on the supplied connection" do
    _stores, pool = build_sqlite_persistence
    pool.with_connection do |connection|
      connection.tables.grep(/^phronomy_/).each { |table| connection.drop_table(table) }
      PhronomyActiveRecord.build(connection_pool: pool, dialect: :sqlite)
      expect(connection.tables.grep(/^phronomy_/)).to be_empty
      PhronomyActiveRecord::SchemaV1.install!(connection: connection)
      expect(connection.tables).to include("phronomy_agents", "phronomy_teams", "phronomy_workflow_states")
    end
  end
end
