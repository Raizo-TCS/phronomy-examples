# frozen_string_literal: true

# Deliberately separate from spec/spec_helper.rb: live configuration must not be
# replaced by its offline model, credentials or WebMock setup.
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

RSpec.describe "Trust pipeline live acceptance" do
  cases = %w[invoice accepted iteration_limit approval-yes approval-no approval-cancel].freeze
  root = File.expand_path("..", __dir__)

  before(:context) do
    FileUtils.mkdir_p(File.join(root, "tmp"))
    @reports = ENV["PHRONOMY_TRUST_REPORT_DIR"] || Dir.mktmpdir("trust-live-", File.join(root, "tmp"))
    FileUtils.mkdir_p(@reports)
    @outcomes = {}
    puts "Trust acceptance reports: #{@reports}"
  end

  after(:context) do
    outcomes = cases.to_h { |name| [name, @outcomes.fetch(name, {"status" => "not_run"})] }
    counts = outcomes.values.group_by { |item| item.fetch("status") }.transform_values(&:length)
    summary = {"cases" => outcomes, "counts" => counts}
    File.open(File.join(@reports, "summary.json"), File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
      file.write(JSON.pretty_generate(summary) + "\n")
    end
    puts "Trust acceptance totals: #{counts.map { |name, count| "#{name}=#{count}" }.join(", ")}"
  end

  cases.each do |name|
    it "passes #{name} against the configured server" do
      report_path = File.join(@reports, "#{name}.json")
      log_path = File.join(@reports, "#{name}.log")
      out, err, process = Open3.capture3(RbConfig.ruby,
        File.join(root, "scripts/verify_trust_pipeline.rb"),
        "--case", name, "--report", report_path, chdir: root)
      File.open(log_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(out + err) }
      report = File.file?(report_path) ? JSON.parse(File.read(report_path)) : {"status" => "missing_report"}
      @outcomes[name] = {"status" => report.fetch("status", "incomplete"),
                         "exit_code" => process.exitstatus, "report" => report_path, "log" => log_path}
      diagnostic = "#{name}: #{@outcomes[name].fetch("status").upcase}; " \
        "exit=#{process.exitstatus.inspect}; report=#{report_path}; log=#{log_path}"
      # blocked is an unmet acceptance criterion, not a pending example that
      # would let RSpec and the overall verification exit successfully.
      expect([process.exitstatus, report["status"], report["observation_complete"], report["webmock_loaded"]])
        .to eq([0, "passed", true, false]), diagnostic
    end
  end
end
