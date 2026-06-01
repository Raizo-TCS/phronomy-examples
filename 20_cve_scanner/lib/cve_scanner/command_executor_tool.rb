# frozen_string_literal: true

require "open3"
require "timeout"

# Tool: executes a single pre-approved shell command on the host.
# Only commands matching the allowlist are permitted for security.
class CveScanner::CommandExecutorTool < Phronomy::Agent::Context::Capability::Base
  description "Execute a pre-approved shell command and return its output"

  param :command, type: :string, desc: "The shell command to execute (must be on the allowlist)"

  # Commands permitted for the CHECK phase (read-only operations).
  CHECK_PATTERNS = [
    /\Adpkg -l [a-z0-9][a-z0-9.+\-]*\z/,
    /\Adpkg --list [a-z0-9][a-z0-9.+\-]*\z/,
    /\Adpkg --list linux-image-\*/,
    /\Aapt-cache policy [a-z0-9][a-z0-9.+\-]*\z/,
    /\Auname -r\z/,
    /\Adpkg -s [a-z0-9][a-z0-9.+\-]*\z/,
    /\Alsmod\z/,
    /\Amodinfo [a-z0-9_]+\z/,
    /\Alsb_release -[a-z]+\z/
  ].freeze

  # Commands permitted for the REMEDIATION phase.
  REMEDIATION_PATTERNS = [
    /\Aapt-get install --only-upgrade [a-z0-9][a-z0-9.+\-]+(=[a-zA-Z0-9.+\-~:]+)?\z/,
    /\Aapt-get upgrade [a-z0-9][a-z0-9.+\-]*\z/
  ].freeze

  ALL_PATTERNS = (CHECK_PATTERNS + REMEDIATION_PATTERNS).freeze

  def execute(command:)
    cmd = command.strip
    unless ALL_PATTERNS.any? { |pattern| cmd.match?(pattern) }
      return "error=Command not permitted: #{cmd}"
    end

    stdout_and_stderr, status = Timeout.timeout(30) { Open3.capture2e(cmd) }
    exit_code = status.exitstatus
    output = stdout_and_stderr.strip.slice(0, 2000)

    "exit_code=#{exit_code}\n#{output}"
  rescue Errno::ENOENT => e
    "error=#{e.message}"
  end
end
