#!/usr/bin/env ruby
# frozen_string_literal: true

# 14_code_review/batch_review.rb
#
# Runs Security / Performance / Readability review on every phronomy source
# file with more than MIN_LINES lines.  Improvement and Eval are skipped so
# the run stays fast enough to cover the full codebase.
#
# Usage:
#   bundle exec ruby 14_code_review/batch_review.rb

require_relative "../shared/llm_config"
require "phronomy"
require_relative "reviewers"
require_relative "tracer"

# Suppress the default per-thread backtrace printing; exceptions are
# caught via Thread#value in the rescue block below.
Thread.report_on_exception = false

MIN_LINES = 20
# Chunk size derived from the model's actual context window (LLMConfig::CONTEXT_WINDOW).
# Overhead: system prompt + static knowledge ≈ 500 tokens, plus max_output_tokens reserved
# by the LLM server so it must not count against the prompt budget.
# Ruby is symbol-heavy: use 1.5 chars/token with a 0.75 safety factor.
BATCH_OVERHEAD_TOKENS = 500 + REVIEWER_MAX_OUTPUT_TOKENS
MAX_CHUNK_CHARS = ((LLMConfig::CONTEXT_WINDOW - BATCH_OVERHEAD_TOKENS) * 1.5 * 0.75).to_i

LIB_ROOT = File.expand_path("../../phronomy/lib", __dir__)

Phronomy.configure do |c|
  c.tracer = Phronomy::Tracing::NullTracer.new
end

# ---- collect target files ----
all_files = Dir.glob("#{LIB_ROOT}/**/*.rb").sort
target_files = all_files.select { |f| File.readlines(f).count >= MIN_LINES }

puts "=== phronomy Source Code Review (batch) ==="
puts "Target: #{target_files.size} files (>= #{MIN_LINES} lines) out of #{all_files.size} total"
puts "Reviewers: Security / Performance / Readability (parallel)"
puts "=" * 60
puts

total_start = Time.now
findings_by_file = {}

target_files.each_with_index do |path, idx|
  rel = path.sub("#{LIB_ROOT}/", "")
  line_count = File.readlines(path).count
  source = File.read(path)
  # Split into context-window-safe chunks so no information is truncated.
  splitter = Phronomy::Splitter::RecursiveSplitter.new(
    chunk_size: MAX_CHUNK_CHARS,
    chunk_overlap: 200
  )
  chunks = splitter.split({ text: source, metadata: { file: rel } })
  chunk_texts = chunks.map { |c| c[:text] }

  print "[#{idx + 1}/#{target_files.size}] #{rel} (#{line_count} lines, #{chunk_texts.size} chunk(s)) ... "
  $stdout.flush

  start = Time.now

  # Review each chunk; collect findings per perspective across all chunks.
  all_security     = []
  all_performance  = []
  all_readability  = []
  all_abstraction  = []

  chunk_texts.each_with_index do |chunk, cidx|
    label = chunk_texts.size > 1 ? " chunk #{cidx + 1}/#{chunk_texts.size}" : ""
    print label.empty? ? "" : "\n  [chunk #{cidx + 1}] "

    sec_t = Thread.new { SecurityReviewerAgent.new.invoke(chunk)[:output] }
    per_t = Thread.new { PerformanceReviewerAgent.new.invoke(chunk)[:output] }
    red_t = Thread.new { ReadabilityReviewerAgent.new.invoke(chunk)[:output] }
    abs_t = Thread.new { AbstractionConsistencyReviewerAgent.new.invoke(chunk)[:output] }

    begin
      all_security    << sec_t.value
      all_performance << per_t.value
      all_readability << red_t.value
      all_abstraction << abs_t.value
    rescue Phronomy::ContextLengthError, Phronomy::TransportError => e
      warn "\n  [SKIP chunk #{cidx + 1}] #{e.class}: #{e.message}"
    end
  end

  security    = all_security.join("\n")
  performance = all_performance.join("\n")
  readability = all_readability.join("\n")
  abstraction = all_abstraction.join("\n")

  elapsed = ((Time.now - start) * 1000).to_i
  puts "done (#{elapsed}ms)"

  findings_by_file[rel] = {
    lines:       line_count,
    chunks:      chunk_texts.size,
    elapsed_ms:  elapsed,
    security:    security.strip,
    performance: performance.strip,
    readability: readability.strip,
    abstraction: abstraction.strip
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
