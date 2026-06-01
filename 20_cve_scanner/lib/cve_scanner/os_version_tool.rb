# frozen_string_literal: true

# Tool: runs lsb_release and uname to detect the host OS version.
class CveScanner::OsVersionTool < Phronomy::Agent::Context::Capability::Base
  description "Detect the Ubuntu OS version and kernel version of the host system"

  def execute
    os_version    = `lsb_release -rs 2>/dev/null`.strip
    kernel_version = `uname -r 2>/dev/null`.strip
    "os_version=#{os_version}, kernel_version=#{kernel_version}"
  end
end
