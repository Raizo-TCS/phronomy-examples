# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Operator note delivery", type: :request do
  after { Phronomy.reset_runtime! }

  it "uses the same delivery boundary before enqueuing a chat response" do
    scan = Scan.create!(cve_ids: [], status: "done", state_json: {"user_notes" => []})
    received = []
    allow(ActionCable.server).to receive(:broadcast) do |stream, payload|
      expect(Phronomy::Runtime.in_event_loop_context?).to be(false)
      expect(Rails.application.executor.active?).to be(true)
      received << [stream, payload]
    end
    expect(ScanChatJob).to receive(:perform_later).with(scan.id, "operator note") do
      expect(received).to eq([["scan_#{scan.id}", {type: "user_note", content: "operator note"}]])
    end
    post "/scans/#{scan.id}/note", params: {note: " operator note "}
    expect(response).to have_http_status(:accepted)
    expect(scan.reload.state_json["user_notes"]).to eq(["operator note"])
  end
end
