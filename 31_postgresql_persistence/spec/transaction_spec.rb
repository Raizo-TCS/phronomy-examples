# frozen_string_literal: true

require "spec_helper"

RSpec.describe "ActiveRecord PostgreSQL Persistence transaction boundary" do
  let(:persistence) { build_postgresql_persistence.first }

  it "keeps watermark verification and the following write in one transaction" do
    root = build_agent_root
    persistence.agents.create(root)

    content_id = nil
    persistence.transaction do |tx|
      expect(
        tx.assert_agent_watermark!(
          agent_id: root.agent_id,
          agent_revision: 0,
          journal_position: 0
        )
      ).to be(true)

      content_id = tx.contents.put_text("after-watermark")
    end

    expect(persistence.contents.fetch_text(content_id)).to eq("after-watermark")
  end

  it "rolls back a write made before a stale watermark check" do
    root = build_agent_root
    persistence.agents.create(root)
    advanced = root.with(agent_revision: 1)
    persistence.agents.save(root.agent_id, expected_revision: 0, root: advanced)

    content_id = nil
    expect do
      persistence.transaction do |tx|
        content_id = tx.contents.put_text("must-roll-back")
        tx.assert_agent_watermark!(
          agent_id: root.agent_id,
          agent_revision: 0,
          journal_position: 0
        )
      end
    end.to raise_error(Phronomy::Persistence::ConflictError)

    expect(persistence.contents.exist?(content_id)).to be(false)
  end
end
