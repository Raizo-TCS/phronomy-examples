# frozen_string_literal: true

RSpec.shared_examples "a neutral SQL resource driver" do
  it "accepts unrelated resource IDs, nullable indexed metadata and physical mappings" do
    persistence = build_persistence
    pool = persistence.backend.connection_pool
    resource = Phronomy::Storage::Resource.new(id: "inventory.items", kind: :records,
      attributes: {code: :nullable_string, quantity: :integer, enabled: :boolean},
      indexes: {code: [:code]}, unique: [{name: :unique_code, fields: [:code], where: {}}])
    pool.with_connection do |connection|
      connection.create_table(:inventory_items, id: false) do |table|
        table.string :item_key, null: false
        table.integer :revision, null: false
        table.text :envelope, null: false
        table.string :code
        table.integer :quantity, null: false
        table.boolean :enabled, null: false
      end
      connection.add_index(:inventory_items, :item_key, unique: true)
      connection.add_index(:inventory_items, :code, unique: true, name: "inventory_unique_code")
    end
    backend = PhronomyExamples::Storage::Backend.new(connection_pool: pool, resources: [resource], dialect: storage_dialect,
      mappings: {resource.id => {table: "inventory_items", key: "item_key", revision: "revision", record: "envelope",
        attributes: {code: "code", quantity: "quantity", enabled: "enabled"}, constants: {}, constraints: {unique_code: "inventory_unique_code"}}})
    records = backend.view.records(resource)
    record = Phronomy::Storage::DurableRecord.new(record_type: "inventory", format_version: "0.1", payload: {"uninterpreted" => true})
    %w[first second].each { |key| records.insert(key: key, revision: 7, attributes: {code: nil, quantity: 0, enabled: false}, record: record) }
    expect(records.scan(index: :code, equals: {code: nil}).map(&:key)).to eq(%w[first second])
    records.insert(key: "third", revision: 0, attributes: {code: "unique", quantity: 5, enabled: true}, record: record)
    expect do
      records.insert(key: "fourth", revision: 0, attributes: {code: "unique", quantity: 5, enabled: true}, record: record)
    end.to raise_error(Phronomy::Storage::UniqueConstraintError) { |error| expect(error.constraint).to eq(:unique_code) }
    records.delete_matching(index: :code, equals: {code: nil})
    expect(records.read("first")).to be_nil
    expect(records.fetch("third").attributes).to eq(code: "unique", quantity: 5, enabled: true)
  ensure
    pool&.with_connection { |connection| connection.drop_table(:inventory_items, if_exists: true) }
  end

  it "rejects invalid physical names before any storage operation" do
    resource = Phronomy::Storage::Resource.new(id: "arbitrary", kind: :records)
    expect do
      PhronomyExamples::Storage::Mapping.new(resource,
        table: "bad; DROP TABLE other", key: "id", revision: "revision", record: "record",
        attributes: {}, constants: {}, constraints: {})
    end.to raise_error(ArgumentError, /identifiers/)
  end
end
