#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require "stringio"
require_relative "../shared/llm_config"
require_relative "support/trust_acceptance_observer"

options = {interval: 30}
cases = %w[invoice accepted iteration_limit approval-yes approval-no approval-cancel]
OptionParser.new do |parser|
  parser.banner = "Usage: ruby scripts/verify_trust_pipeline.rb --case CASE --report PATH"
  parser.on("--case CASE", cases) { |value| options[:case] = value }
  parser.on("--report PATH") { |value| options[:path] = File.expand_path(value) }
  parser.on("--snapshot-interval SECONDS", Float) { |value| options[:interval] = value }
end.parse!
abort "Both --case and --report are required" unless options[:case] && options[:path]

observer = TrustAcceptanceObserver.new(path: options[:path], interval: options[:interval])
records = observer.records
records[:case] = options[:case]
records[:status] = "running"
records[:model] = LLMConfig::MODEL
records[:provider] = LLMConfig::PROVIDER
records[:server_version] = ENV["PHRONOMY_SERVER_VERSION"] # Record unknown as null.
records[:webmock_loaded] = !!defined?(WebMock)
records[:versions] = %w[phronomy ruby_llm faraday faraday-net_http].to_h { |name| [name, Gem.loaded_specs[name]&.version&.to_s] }
failure = nil
exit_status = 0
previous_stdin = $stdin
begin
  observer.start
  if options[:case].start_with?("approval-")
    $stdin = StringIO.new(options[:case].delete_prefix("approval-") + "\n")
    file = "approval_demo.rb"
  else
    file = {"invoice" => "structured_agent_demo.rb", "accepted" => "lifetime_demo.rb", "iteration_limit" => "iteration_limit_demo.rb"}.fetch(options[:case])
  end
  load File.expand_path("../19_trust_pipeline/#{file}", __dir__)
rescue SystemExit => error
  exit_status = error.status
  failure = error unless error.success?
rescue StandardError, SignalException => error
  failure = error
ensure
  observer.finish
  $stdin = previous_stdin
end

records[:primary_error] = failure && observer.exception(failure)
result = JSON.parse(JSON.generate(records[:results].last&.fetch(:value)))
released = records[:releases].any? { |release| release[:value] == true }
approved = records[:approvals].length
tools = records[:tool_executions]
valid_result = result && result["failure"].nil?
passed = case options[:case]
when "invoice"
  failure.nil? && exit_status.zero? && released
when "accepted", "iteration_limit"
  failure.nil? && released && valid_result && result["termination_reason"] == options[:case]
when "approval-yes"
  failure.nil? && released && approved == 1 && tools == 1 &&
    records[:decisions].map { |item| item[:approved] } == [true] &&
    valid_result && %w[accepted iteration_limit].include?(result["termination_reason"])
when "approval-no"
  failure.nil? && released && approved == 1 && tools.zero? &&
    records[:decisions].map { |item| item[:approved] } == [false] &&
    valid_result && result["termination_reason"] == "tool_rejected"
when "approval-cancel"
  failure.is_a?(Phronomy::CancellationError) && released && approved == 1 && tools.zero? && records[:decisions].empty?
end
interrupted = records[:primary_error]&.any? { |item| item[:signal] }
records[:observation_complete] = records[:observer_errors].empty? && !records[:requests].empty? &&
  (records[:webmock_loaded] || records[:http_attempts].length >= records[:requests].length)
passed &&= records[:observation_complete]
records[:status] = if interrupted
  "interrupted"
elsif !records[:observer_errors].empty?
  "failed"
elsif failure.is_a?(Phronomy::LLMAdapter::StructuredOutputUnsupportedError)
  "blocked"
else
  passed ? "passed" : "failed"
end
records[:completed_at] = Time.now.utc.iso8601(6)
observer.write
warn "Trust acceptance #{options[:case]}: #{records[:status]} (#{options[:path]})"
raise failure if interrupted
exit({"passed" => 0, "blocked" => 2}.fetch(records[:status], 1))
