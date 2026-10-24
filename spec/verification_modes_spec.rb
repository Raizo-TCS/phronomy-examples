# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "timeout"
require "tmpdir"

RSpec.describe "Repository verification modes" do
  let(:root) { File.expand_path("..", __dir__) }

  # Run the complete shell entry point against controlled commands. Unexpected
  # application, Rails or browser execution is recorded and fails immediately.
  def run_verifier(*arguments, invalid_syntax: false, failed_suite: nil)
    Dir.mktmpdir("verification-modes-") do |dir|
      scripts = File.join(dir, "scripts")
      bin = File.join(dir, "commands")
      FileUtils.mkdir_p([scripts, bin])
      %w[verify_examples.sh verification_cli.sh verification_trust.sh verification_processes.sh].each do |name|
        FileUtils.cp(File.join(root, "scripts", name), scripts)
      end
      %w[09_rails_chat 15_rails_secure_chat 18_rails_agent_job 20_cve_scanner
        30_sqlite_persistence 31_postgresql_persistence 01_basic_chain].each do |name|
        FileUtils.mkdir_p(File.join(dir, name))
      end
      File.write(File.join(dir, "test_approval_lmstudio.rb"), 'raise "must not execute"')
      File.write(File.join(dir, "01_basic_chain/run.rb"), invalid_syntax ? "def (" : 'raise "must not execute"')
      command = <<~'RUBY'
        require "json"
        require "rbconfig"
        name = File.basename($PROGRAM_NAME)
        File.open(ENV.fetch("VERIFY_COMMAND_LOG"), "a") do |file|
          file.puts(JSON.generate(command: name, arguments: ARGV, directory: File.basename(Dir.pwd)))
        end
        if name == "python3"
          exit 0 # The independent source-API preflight is outside this test.
        elsif name == "bundle"
          if ARGV.take(3) == ["exec", "ruby", "-e"]
            puts "0.30.1\t/fixture/gems/phronomy-0.30.1"
            exit 0
          elsif ARGV.take(3) == ["exec", "ruby", "-c"]
            exec RbConfig.ruby, "-c", ARGV.fetch(3)
          elsif ARGV.take(2) == ["exec", "rspec"] && !ARGV.include?("integration/trust_pipeline_spec.rb")
            suite = File.basename(Dir.pwd) == "30_sqlite_persistence" ? "sqlite" : "root"
            exit 7 if ENV["VERIFY_FAILED_SUITE"] == suite
            puts "2 examples, 0 failures"
            exit 0
          end
        end
        warn "Blocked external execution: #{name} #{ARGV.inspect}"
        exit 23
      RUBY
      %w[bundle python3 curl node npm].each do |name|
        path = File.join(bin, name)
        File.write(path, "#!#{RbConfig.ruby}\n#{command}")
        File.chmod(0o755, path)
      end
      log = File.join(dir, "commands.jsonl")
      env = {"PATH" => "#{bin}:#{ENV.fetch("PATH")}", "VERIFY_COMMAND_LOG" => log,
             "VERIFY_FAILED_SUITE" => failed_suite, "OPENAI_API_KEY" => "verification-fixture-key",
             "PHRONOMY_PATH" => nil,
             "RUBYOPT" => nil, "RUBYLIB" => nil, "BUNDLE_GEMFILE" => nil,
             "BUNDLE_BIN_PATH" => nil, "BUNDLER_SETUP" => nil, "BASH_ENV" => nil}
      out, err, status = Timeout.timeout(20) do
        Open3.capture3(env, "bash", File.join(scripts, "verify_examples.sh"), *arguments)
      end
      calls = File.exist?(log) ? File.readlines(log).map { |line| JSON.parse(line) } : []
      [out, err, status, calls]
    end
  end

  it "keeps offline checks and explicitly skips every live and Rails path in syntax-only mode" do
    out, err, status, calls = run_verifier("--syntax-only")
    expect(status.success?).to be(true), "#{out}\n#{err}"
    expect(out).to include("all 6 live trust acceptance cases not run", "all 4 smoke tests skipped")
    expect(out.scan("Rails smoke tests not run (--syntax-only):").length).to eq(4)
    expect(calls.map { |call| call.fetch("command") }.uniq.sort).to eq(%w[bundle python3])
    bundle_calls = calls.select { |call| call["command"] == "bundle" }
    expect(bundle_calls.map { |call| call.fetch("arguments").take(3) }.uniq).to contain_exactly(
      %w[exec ruby -e], %w[exec ruby -c], %w[exec rspec spec], %w[exec rspec]
    )
    expect(bundle_calls).to include(include("directory" => "30_sqlite_persistence", "arguments" => %w[exec rspec]))
  end

  it "still fails syntax-only verification when a CLI file has invalid Ruby syntax" do
    out, _err, status, _calls = run_verifier("--syntax-only", invalid_syntax: true)
    expect(status.success?).to be(false)
    expect(out).to include("syntax error", "all 4 smoke tests skipped")
  end

  %w[root sqlite].each do |suite|
    it "preserves an offline #{suite} suite failure in syntax-only mode" do
      out, _err, status, _calls = run_verifier("--syntax-only", failed_suite: suite)
      expect(status.success?).to be(false)
      expect(out).to include((suite == "root") ? "current example API regression tests" : "rspec failed")
    end
  end

  it "retains live acceptance, CLI execution and all four Rails checks in default mode" do
    out, _err, status, calls = run_verifier
    expect(status.success?).to be(false) # Controlled commands reject live work.
    arguments = calls.map { |call| call.fetch("arguments") }
    expect(arguments).to include(include("integration/trust_pipeline_spec.rb"), %w[exec ruby 01_basic_chain/run.rb])
    ports = calls.select { |call| call["arguments"].include?("-rsocket") }.map { |call| call["arguments"].last }
    expect(ports).to eq(%w[3009 3015 3018 3020])
    expect(out).to include("Rails: db + Zeitwerk + server + health + Playwright GUI")
    expect(out).not_to include("Rails smoke tests not run")
  end

  it "stops before offline suites and application execution in preflight-only mode" do
    out, err, status, calls = run_verifier("--preflight-only")
    expect(status.success?).to be(true), "#{out}\n#{err}"
    expect(out).to include("preflight passed")
    expect(calls.select { |call| call["command"] == "bundle" }.map { |call| call["arguments"].take(3) }.uniq)
      .to contain_exactly(%w[exec ruby -e], %w[exec ruby -c])
  end
end
