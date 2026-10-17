#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require_relative "support/trust_acceptance_observer"

options = {interval: 5}
OptionParser.new do |parser|
  parser.banner = "Usage: ruby scripts/observe_trust_cli.rb --report PATH [--snapshot-interval SECONDS]"
  parser.on("--report PATH") { |value| options[:path] = File.expand_path(value) }
  parser.on("--snapshot-interval SECONDS", Float) { |value| options[:interval] = value }
end.parse!
abort "--report is required; unexpected arguments are not supported" unless options[:path] && ARGV.empty?

# Flush partial output before an external cutoff. No request setting is changed.
$stdout.sync = $stderr.sync = true
observer = TrustAcceptanceObserver.new(path: options[:path], interval: options[:interval])
observer.annotate(example: "19_trust_pipeline", status: "running", pid: Process.pid,
  snapshot_interval_seconds: options[:interval], server_version: ENV["PHRONOMY_SERVER_VERSION"],
  webmock_loaded: !!defined?(WebMock))
failure = nil
diagnostic_error = nil
begin
  observer.start
  require_relative "../shared/llm_config"
  observer.annotate(model: LLMConfig::MODEL, provider: LLMConfig::PROVIDER,
    versions: %w[phronomy ruby_llm faraday faraday-net_http].to_h { |name| [name, Gem.loaded_specs[name]&.version&.to_s] })
  load File.expand_path("../19_trust_pipeline/run.rb", __dir__)
rescue StandardError, SignalException, SystemExit => error
  failure = error
ensure
  begin
    observer.finish
  rescue => error
    diagnostic_error = error
  end
end

records = observer.records
released_ids = records[:releases].select { |item| item[:owner] == "Phronomy::GeneratorVerifier" && item[:value] == true }.map { |item| item[:id] }
pipeline_ids = records[:pipelines].map { |item| item[:id] }.uniq
released = if !pipeline_ids.empty? && records[:observer_errors].empty? && diagnostic_error.nil?
  (pipeline_ids - released_ids).empty?
end
chain = failure && observer.exception(failure)
status = if chain&.any? { |item| item[:signal] }
  "interrupted"
elsif failure && !(failure.is_a?(SystemExit) && failure.success?)
  "failed"
elsif diagnostic_error || !records[:observer_errors].empty?
  "observation_failed"
else
  "completed"
end
begin
  observer.annotate(status: status, primary_error: chain,
    diagnostic_error: diagnostic_error && observer.exception(diagnostic_error), completed_at: Time.now.utc.iso8601(6),
    all_observed_pipelines_released: released)
rescue => error
  diagnostic_error ||= error
end
warn "CLI observation: #{status} (#{options[:path]})"
# Preserve the application exception (including signals), even if diagnostics fail.
raise failure if failure
raise diagnostic_error if diagnostic_error
exit 1 if status == "observation_failed"
