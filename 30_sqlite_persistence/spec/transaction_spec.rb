# frozen_string_literal: true

require "spec_helper"

RSpec.describe "ActiveRecord SQLite Persistence transaction boundary" do
  let(:stores) { build_sqlite_persistence.first }

  it "keeps watermark verification and the following write in one transaction" do
    root = build_agent_root
    stores.agent.agents.create(root)

    content_id = nil
    stores.agent.transaction do |tx|
      expect(
        tx.assert_agent_watermark!(
          agent_id: root.agent_id,
          agent_revision: 0,
          journal_position: 0
        )
      ).to be(true)

      content_id = tx.contents.put_text("after-watermark")
    end

    expect(stores.agent.contents.fetch_text(content_id)).to eq("after-watermark")
  end

  it "rolls back a write made before a stale watermark check" do
    root = build_agent_root
    stores.agent.agents.create(root)
    advanced = root.with(agent_revision: 1)
    stores.agent.agents.save(root.agent_id, expected_revision: 0, root: advanced)

    content_id = nil
    expect do
      stores.agent.transaction do |tx|
        content_id = tx.contents.put_text("must-roll-back")
        tx.assert_agent_watermark!(
          agent_id: root.agent_id,
          agent_revision: 0,
          journal_position: 0
        )
      end
    end.to raise_error(Phronomy::Persistence::ConflictError)

    expect(stores.agent.contents.exist?(content_id)).to be(false)
  end
  it "propagates ActiveRecord::Rollback after rolling back the inner savepoint" do
    outer_id = inner_id = nil
    failure = ActiveRecord::Rollback.new("explicit rollback")
    stores.agent.transaction do |outer|
      outer_id = outer.contents.put_text("outer")
      expect do
        stores.agent.transaction do |inner|
          inner_id = inner.contents.put_text("inner")
          raise failure
        end
      end.to raise_error { |error| expect(error).to equal(failure) }
      expect(outer.contents.exist?(inner_id)).to be(false)
    end
    expect(stores.agent.contents.exist?(outer_id)).to be(true)
    expect(stores.agent.contents.exist?(inner_id)).to be(false)
  end
end
