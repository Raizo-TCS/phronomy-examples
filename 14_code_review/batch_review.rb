#!/usr/bin/env ruby
# frozen_string_literal: true

# 14_code_review/batch_review.rb
#
# Runs Security / Performance / Readability / Abstraction review on every
# phronomy source file with more than MIN_LINES lines. Improvement and quality
# scoring are skipped so the run stays fast enough to cover the full codebase.
#
# Usage:
#   bundle exec ruby 14_code_review/batch_review.rb

require_relative "../shared/llm_config"
require "phronomy"
require_relative "reviewers"
require_relative "tracer"

MIN_LINES = 20
BATCH_OVERHEAD_TOKENS = 500 + REVIEWER_MAX_OUTPUT_TOKENS
MAX_CHUNK_CHARS = ((LLMConfig::CONTEXT_WINDOW - BATCH_OVERHEAD_TOKENS) * 1.5 * 0.75).to_i

LIB_ROOT = File.expand_path("../../phronomy/lib", __dir__)

Phronomy.configure do |c|
  c.tracer = Phronomy::Tracing::NullTracer.new
end

REVIEWERS = {
  security: SecurityReviewerAgent,
  performance: PerformanceReviewerAgent,
  readability: ReadabilityReviewerAgent,
  abstraction: AbstractionConsistencyReviewerAgent
}.freeze

# ---- collect target files ----
all_files = Dir.glob("#{LIB_ROOT}/**/*.rb").sort
target_files = all_files.select { |f| File.readlines(f).count >= MIN_LINES }

puts "=== phronomy Source Code Review (batch) ==="
puts "Target: #{target_files.size} files (>= #{MIN_LINES} lines) out of #{all_files.size} total"
puts "Reviewers: Security / Performance / Readability / Abstraction (async Agent invocations)"
puts "=" * 60
puts

total_start = Time.now
findings_by_file = {}

target_files.each_with_index do |path, idx|
  rel = path.sub("#{LIB_ROOT}/", "")
  line_count = File.readlines(path).count
  source = File.read(path)

  splitter = Phronomy::VectorStore::Splitter::RecursiveSplitter.new(
    chunk_size: MAX_CHUNK_CHARS,
    chunk_overlap: 200
  )
  chunks = splitter.split({text: source, metadata: {file: rel}})
  chunk_texts = chunks.map { |c| c[:text] }

  print "[#{idx + 1}/#{target_files.size}] #{rel} (#{line_count} lines, #{chunk_texts.size} chunk(s)) ... "
  $stdout.flush

  start = Time.now
  findings = REVIEWERS.transform_values { [] }

  chunk_texts.each_with_index do |chunk, cidx|
    print chunk_texts.size > 1 ? "\n  [chunk #{cidx + 1}] " : ""

    operations = REVIEWERS.map do |key, agent_class|
      agent = agent_class.new(knowledge: [agent_class.review_knowledge])
      [key, agent.invoke_async(chunk)]
    end

    # This script is the external CLI caller, not an EventLoop callback, so
    # waiting for the already-started Agent Tasks here is valid. No raw Threads
    # are created by the application.
    operations.each do |key, task|
      begin
        result = task.wait_result
        findings[key] << result[:output].to_s
      rescue Phronomy::ContextLengthError, Phronomy::TransportError => e
        warn "\n  [SKIP #{key} chunk #{cidx + 1}] #{e.class}: #{e.message}"
      rescue => e
        warn "\n  [ERROR #{key} chunk #{cidx + 1}] #{e.class}: #{e.message}"
      end
    end
  end

  elapsed = ((Time.now - start) * 1000).to_i
  puts "done (#{elapsed}ms)"

  findings_by_file[rel] = {
    lines: line_count,
    chunks: chunk_texts.size,
    elapsed_ms: elapsed,
    security: findings[:security].join("\n").strip,
    performance: findings[:performance].join("\n").strip,
    readability: findings[:readability].join("\n").strip,
    abstraction: findings[:abstraction].join("\n").strip
  }
end

total_elapsed = ((Time.now - total_start) * 1000).to_i

# ---- print results ----
puts
puts "=" * 60
puts "RESULTS"
puts "=" * 60

findings_by_file.each do |rel, data|
  clean = ->(text) { text.gsub(/No (security|performance|readability|abstraction[- ]level) issues found\.?/i, "").strip }

  sec = clean.call(data[:security])
  per = clean.call(data[:performance])
  red = clean.call(data[:readability])
  abs = clean.call(data[:abstraction])

  next if sec.empty? && per.empty? && red.empty? && abs.empty?

  puts
  puts "--- #{rel} (#{data[:lines]} lines, #{data[:chunks]} chunk(s), #{data[:elapsed_ms]}ms) ---"
  puts "  [Security]"
  sec.empty? ? puts("    (none)") : sec.each_line { |l| puts "    #{l.chomp}" }
  puts "  [Performance]"
  per.empty? ? puts("    (none)") : per.each_line { |l| puts "    #{l.chomp}" }
  puts "  [Readability]"
  red.empty? ? puts("    (none)") : red.each_line { |l| puts "    #{l.chomp}" }
  puts "  [Abstraction Consistency]"
  abs.empty? ? puts("    (none)") : abs.each_line { |l| puts "    #{l.chomp}" }
end

puts
puts "=" * 60
puts "Total: #{target_files.size} files reviewed in #{(total_elapsed / 1000.0).round(1)}s"
puts "=" * 60
