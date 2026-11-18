# frozen_string_literal: true

require_relative "spec_helper"

module CveScanner
end

require_relative "../20_cve_scanner/lib/cve_scanner/command_executor_tool"

RSpec.describe CveScanner::CommandExecutorTool do
  subject(:tool) { described_class.new }

  let(:status) { instance_double(Process::Status, exitstatus: 0) }

  {
    "dpkg -l openssl" => ["dpkg", "-l", "openssl"],
    "dpkg --list openssl" => ["dpkg", "--list", "openssl"],
    "dpkg --list linux-image-*" => ["dpkg", "--list", "linux-image-*"],
    "apt-cache policy libssl3" => ["apt-cache", "policy", "libssl3"],
    "uname -r" => ["uname", "-r"],
    "dpkg -s openssl" => ["dpkg", "-s", "openssl"],
    "lsmod" => ["lsmod"],
    "modinfo iwlwifi" => ["modinfo", "iwlwifi"],
    "lsb_release -a" => ["lsb_release", "-a"],
    "apt-get install --only-upgrade openssl=3.0.2-0ubuntu1.18" => ["apt-get", "install", "--only-upgrade", "openssl=3.0.2-0ubuntu1.18"],
    "apt-get upgrade openssl" => ["apt-get", "upgrade", "openssl"]
  }.each do |command, arguments|
    it "passes #{command.inspect} as command arguments" do
      expect(Open3).to receive(:capture2e).with(*arguments).and_return(["checked\n", status])

      expect(tool.execute(command: command)).to eq("exit_code=0\nchecked")
    end
  end

  [
    "dpkg --list linux-image-*; printf unexpected",
    "dpkg --list linux-image-* && printf unexpected",
    "dpkg --list linux-image-* || printf unexpected",
    "dpkg --list linux-image-* | cat",
    "dpkg --list linux-image-* &",
    "dpkg --list linux-image-* > output",
    "dpkg --list linux-image-*\nprintf unexpected",
    "dpkg --list linux-image-*$(printf unexpected)",
    "dpkg --list linux-image-*`printf unexpected`",
    "dpkg --list linux-image-* extra",
    "uname -r; printf unexpected",
    "apt-get upgrade openssl; printf unexpected"
  ].each do |command|
    it "rejects the complete command #{command.inspect} before process execution" do
      expect(Open3).not_to receive(:capture2e)

      expect(tool.execute(command: command)).to eq("error=Command not permitted: #{command}")
    end
  end

  it "retains surrounding-whitespace normalization" do
    expect(Open3).to receive(:capture2e).with("uname", "-r").and_return(["kernel\n", status])

    expect(tool.execute(command: "  uname -r\n")).to eq("exit_code=0\nkernel")
  end

  it "retains the exit status and bounded output" do
    failure = instance_double(Process::Status, exitstatus: 1)
    expect(Open3).to receive(:capture2e).with("dpkg", "-s", "missing").and_return(["x" * 2100, failure])

    expect(tool.execute(command: "dpkg -s missing")).to eq("exit_code=1\n#{"x" * 2000}")
  end

  it "reports an unavailable executable through the existing error result" do
    expect(Open3).to receive(:capture2e).with("uname", "-r").and_raise(Errno::ENOENT, "uname")

    expect(tool.execute(command: "uname -r")).to start_with("error=")
  end
end
