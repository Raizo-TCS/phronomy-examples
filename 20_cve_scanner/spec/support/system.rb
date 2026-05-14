# frozen_string_literal: true

require "capybara/rspec"

# Register a headless Chrome driver with flags required for CI/sandbox environments.
Capybara.register_driver :headless_chrome do |app|
  options = Selenium::WebDriver::Chrome::Options.new
  options.add_argument("--headless=new")
  options.add_argument("--no-sandbox")
  options.add_argument("--disable-dev-shm-usage")
  options.add_argument("--disable-gpu")
  options.add_argument("--window-size=1280,800")
  Capybara::Selenium::Driver.new(app, browser: :chrome, options: options)
end

# Use Puma as the Capybara test server so ActionCable WebSocket connections work.
Capybara.server = :puma, { Silent: true }

# Default wait time for async DOM updates driven by WebSocket events.
Capybara.default_max_wait_time = 8

RSpec.configure do |config|
  # Suspend WebMock entirely for system specs. ChromeDriver communicates over
  # localhost HTTP (127.0.0.1:9515) and WebMock's Net::HTTP patch would block it.
  # Since all external HTTP is replaced with mocks/stubs (CVE_SCANNER_MOCK_LLM=1
  # and the scraper stub below), there is nothing for WebMock to intercept here.
  # We use around(:each) so the WebMock.disable! covers Capybara's own teardown
  # (reset_sessions!) as well — that teardown runs inside example.run.
  config.around(:each, type: :system) do |example|
    WebMock.disable!
    example.run
  ensure
    # Re-hook Net::HTTP and restore the suite-level "block external, allow
    # localhost" policy that rails_helper.rb establishes.
    WebMock.enable!
    WebMock.disable_net_connect!(allow_localhost: true)
  end

  config.before(:each, type: :system) do
    driven_by :headless_chrome

    # The default "test" ActionCable adapter only supports in-process, same-thread
    # delivery and does not push to real WebSocket connections. Switch to "async"
    # so that broadcasts made from the test thread (via perform_enqueued_jobs)
    # are delivered to the headless browser's WebSocket within the same Puma process.
    ActionCable.server.config.cable = { "adapter" => "async" }

    # Stub the Ubuntu CVE scraper to avoid real HTTP requests during system specs.
    # Return a minimal CVE payload with at least one package so the analyst is
    # always called (prevents PATH-C short-circuit) and mock mode exercises PATH-A.
    allow_any_instance_of(CveScanner::UbuntuCveScraperTool).to receive(:execute) do |_, cve_id:|
      {
        priority:    "medium",
        description: "Stub CVE for #{cve_id}.",
        packages:    { "testpkg" => { status: "vulnerable", fix_version: nil } },
        references:  []
      }.to_json
    end
  end

  config.after(:each, type: :system) do
    ActionCable.server.config.cable = { "adapter" => "test" }
  end
end
