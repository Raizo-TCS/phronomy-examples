# frozen_string_literal: true

require "rails_helper"

# System specs: headless Chrome + Selenium + ActionCable (async adapter).
#
# All LLM calls are replaced with fixed mock responses via CVE_SCANNER_MOCK_LLM=1.
# The Ubuntu CVE scraper is stubbed in spec/support/system.rb (no real HTTP).
# ScanJob / ScanFollowupJob use the default :test queue adapter and are executed
# synchronously with perform_enqueued_jobs after the WebSocket subscription is live.
#
# Covered scenarios:
#   BROWSER-1  Scan runs → pipeline log card shown, log lines + result table appear
#   BROWSER-2  After scan → UI enters follow-up mode (chat-input-bar shown)
#   BROWSER-3  "done" keyword → UI resets (chat-input-bar hidden, scan-btn re-enabled)
#   BROWSER-4  Follow-up question → "answered" → stays in follow-up mode
RSpec.describe "CVE Scanner pipeline UI", type: :system do
  include ActiveJob::TestHelper

  # Apply deterministic mock LLM mode (no real LLM calls) for every example.
  around do |example|
    ClimateControl.modify(CVE_SCANNER_MOCK_LLM: "1") { example.run }
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  # Fill in the CVE IDs field and click Start Scan.
  # Returns when the fetch response has arrived (status-line shows "Scan ID:").
  def start_scan(cve_ids: "CVE-2023-52160")
    find("#cve-input").set(cve_ids)
    click_button "Start Scan"
    expect(page).to have_text("Scan ID:", wait: 5)
  end

  # Wait until the WebSocket connection is fully open (readyState OPEN).
  # An additional brief pause covers the subscription handshake (~100 ms on localhost).
  def wait_for_ws_open(timeout: 5)
    require "timeout"
    Timeout.timeout(timeout) do
      loop do
        break if page.evaluate_script("window.ws && window.ws.readyState === 1")
        sleep 0.1
      end
    end
    sleep 0.3 # subscription confirm roundtrip
  end

  # Run every currently enqueued job after ensuring the WebSocket is subscribed.
  def run_enqueued_jobs
    wait_for_ws_open
    perform_enqueued_jobs
  end

  # Type a message in the chat bar, click Send, then wait for the server to
  # enqueue the ScanFollowupJob before running it.
  def send_followup(text)
    initial_count = enqueued_jobs.count
    find("#chat-bar-input").set(text)
    click_button "Send"
    # Wait for the POST /followup fetch to land on the server (job enqueued).
    require "timeout"
    Timeout.timeout(5) { sleep 0.05 until enqueued_jobs.count > initial_count }
    perform_enqueued_jobs
  end

  # ── BROWSER-1: pipeline log populates ─────────────────────────────────────

  describe "BROWSER-1: scan starts and pipeline log populates" do
    it "shows the pipeline log card immediately after clicking Start Scan" do
      visit "/"
      find("#cve-input").set("CVE-2023-52160")
      click_button "Start Scan"
      expect(page).to have_css("#log-card", visible: :visible, wait: 5)
    end

    it "renders log lines and a result table after the job completes" do
      visit "/"
      start_scan
      run_enqueued_jobs
      expect(page).to have_css(".result-table", wait: 8)
      expect(page).to have_text("CVE-2023-52160", wait: 8)
    end
  end

  # ── BROWSER-2: follow-up mode is activated after scan completes ──────────

  describe "BROWSER-2: follow-up mode after scan" do
    before do
      visit "/"
      start_scan
      run_enqueued_jobs
      # Scan halts at awaiting_followup — chat-input-bar becomes visible.
      expect(page).to have_css("#chat-input-bar", visible: :visible, wait: 8)
    end

    it "shows the chat input bar" do
      expect(page).to have_css("#chat-bar-input", visible: :visible)
    end

    it "keeps the Start Scan button disabled" do
      expect(find("#scan-btn")).to be_disabled
    end
  end

  # ── BROWSER-3: "done" keyword ends session and resets the UI ─────────────

  describe "BROWSER-3: 'done' ends the session" do
    before do
      visit "/"
      start_scan
      run_enqueued_jobs
      expect(page).to have_css("#chat-input-bar", visible: :visible, wait: 8)
    end

    it "hides the chat input bar" do
      send_followup("done")
      expect(page).to have_css("#chat-input-bar", visible: :hidden, wait: 8)
    end

    it "re-enables the Start Scan button" do
      send_followup("done")
      expect(find("#scan-btn", wait: 8)).not_to be_disabled
    end

    it "shows the farewell message in the chat log" do
      send_followup("done")
      expect(page).to have_text("Session ended", wait: 8)
    end
  end

  # ── BROWSER-4: answered follow-up stays in follow-up mode ────────────────

  describe "BROWSER-4: follow-up 'answered' keeps follow-up mode active" do
    before do
      visit "/"
      start_scan
      run_enqueued_jobs
      expect(page).to have_css("#chat-input-bar", visible: :visible, wait: 8)
    end

    it "chat input bar remains visible after an answered response" do
      send_followup("What does this mean?")
      # Mock FollowupAgent returns "answered"; the next awaiting_followup
      # broadcast re-shows the chat input bar.
      expect(page).to have_css("#chat-input-bar", visible: :visible, wait: 8)
    end
  end
end
