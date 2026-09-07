# frozen_string_literal: true

require "spec_helper"
require "open3"
require "socket"
require "timeout"

RSpec.describe "Verification process ownership" do
  let(:helper) { File.expand_path("../scripts/verification_processes.sh", __dir__) }

  def run_shell(script, *arguments)
    Timeout.timeout(10) { Open3.capture3("bash", "-c", script, "verification-test", helper, *arguments) }
  end

  it "reports an occupied port without disturbing its current listener" do
    TCPServer.open("127.0.0.1", 0) do |server|
      port = server.addr.fetch(1).to_s
      _out, err, status = run_shell('source "$1"; verification_require_free_port "$2"', port)
      expect(status.success?).to be(false)
      expect(err).to include("Cannot bind verification port #{port}")
      TCPSocket.open("127.0.0.1", port.to_i) do |_client|
        server.accept.close
      end
      expect(server.closed?).to be(false)
    end
  end

  it "stops only tracked children and leaves an unrelated child running" do
    out, err, status = run_shell(<<~'BASH')
      set -euo pipefail
      source "$1"
      sleep 30 & owned=$!
      sleep 30 & unrelated=$!
      trap 'kill "$owned" "$unrelated" 2>/dev/null || true; wait 2>/dev/null || true' EXIT
      SERVER_PIDS=("$owned")
      verification_stop_server "$unrelated"
      kill -0 "$unrelated"
      kill -0 "$owned"
      verification_cleanup_servers
      if kill -0 "$owned" 2>/dev/null; then exit 1; fi
      kill -0 "$unrelated"
      [[ ${#SERVER_PIDS[@]} -eq 0 ]]
    BASH
    expect(status.success?).to be(true), "#{out}\n#{err}"
  end

  it "removes a completed PID by exact identity" do
    out, err, status = run_shell(<<~'BASH')
      set -euo pipefail
      source "$1"
      # Check identity handling with synthetic IDs without signalling processes.
      kill() { [[ "$1" == 12 ]]; }
      wait() { :; }
      SERVER_PIDS=(12 312)
      verification_stop_server 12
      [[ ${#SERVER_PIDS[@]} -eq 1 && "${SERVER_PIDS[0]}" == 312 ]]
    BASH
    expect(status.success?).to be(true), "#{out}\n#{err}"
  end
end
