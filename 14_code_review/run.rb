#!/usr/bin/env ruby
# frozen_string_literal: true

# 14 AI Code Review Pipeline
#
# A comprehensive example demonstrating the breadth of phronomy features:
#
#   InputGuardrail   — validates the file path before processing
#   Splitter         — splits large files into manageable chunks
#   Graph            — orchestrates the full review pipeline
#   ParallelNode     — runs Security / Performance / Readability reviews concurrently
#   Interrupt/Resume — pauses after reviews so the user chooses a priority
#   PromptTemplate   — builds the improvement prompt from variables
#   Agent (streaming)— generates improved code with real-time token output
#   ConversationManager — retains conversation context across repeat sessions
#   OutputGuardrail  — validates that improved code contains a code block
#   OutputParser     — parses structured JSON from Eval scoring response
#   Eval (LLMJudge)  — scores review quality and improvement quality
#   Tracing          — measures elapsed time for every pipeline stage

require_relative "../shared/llm_config"
require "phronomy"
require_relative "guardrails"
require_relative "pipeline"

# Plug in the ConsoleTracer so every span is printed with elapsed time.
Phronomy.configure do |c|
  c.tracer = ConsoleTracer.new
end

INPUT_GUARDRAIL = FileInputGuardrail.new

# Command-line mode: ruby run.rb <path> [priority]
# If a path is given as ARGV[0], run once non-interactively and exit.
CLI_PATH     = ARGV[0]
CLI_PRIORITY = ARGV[1]

# ---- Helpers ----

def display_reviews(reviews)
  puts
  puts "=" * 50
  puts "Review Results"
  puts "=" * 50

  { security: "Security", performance: "Performance", readability: "Readability", abstraction: "Abstraction Consistency" }.each do |key, label|
    text = reviews[key].to_s.strip
    next if text.empty?

    puts "\n#{label}:"
    text.each_line { |l| puts "  #{l.chomp}" }
  end
  puts "=" * 50
end

def ask_priority
  puts "\nWhich area would you like to improve?"
  puts "  1) security"
  puts "  2) performance"
  puts "  3) readability"
  puts "  4) abstraction"
  puts "  5) all (security)"
  print "> "
  $stdout.flush

  choice = $stdin.gets.to_s.strip
  case choice
  when "1", "security"     then "security"
  when "2", "performance"  then "performance"
  when "3", "readability"  then "readability"
  when "4", "abstraction" then "abstraction"
  else "security"
  end
end

def display_eval_scores(scores)
  puts
  puts "=" * 50
  puts "Eval Scores (LLMJudge, scale 0–10)"
  puts "=" * 50
  puts "  Review quality:      #{scores[:review_quality]} / 10"
  puts "  Improvement quality: #{scores[:improvement_quality]} / 10"
  puts "=" * 50
end

# ---- Helpers: run one file through the full pipeline ----

def run_review(app, path, priority_override = nil)
  begin
    INPUT_GUARDRAIL.run!(path)
  rescue Phronomy::GuardrailError => e
    puts "[InputGuardrail] Rejected: #{e.message}"
    return
  end

  source_code = File.read(path)

  puts "\n[Pipeline] Starting review..."
  puts "[ParallelNode] Running Security / Performance / Readability reviews concurrently..."
  state = app.invoke({ file_path: path, source_code: source_code })

  display_reviews(state.reviews)

  priority = priority_override || ask_priority
  puts "\n[Pipeline] Resuming with priority: #{priority}"

  state = app.resume(state: state, input: { priority: priority })

  display_eval_scores(state.eval_scores)
end

# ---- Main ----

app = build_pipeline

puts "=== AI Code Review Pipeline ==="
puts

if CLI_PATH
  # Non-interactive mode: path (and optional priority) given on the command line.
  # If CLI_PATH is a directory, review every *.rb file found directly inside it.
  paths = if File.directory?(CLI_PATH)
    Dir.glob(File.join(CLI_PATH, "*.rb")).sort
  else
    [CLI_PATH]
  end

  paths.each { |p| run_review(app, p, CLI_PRIORITY) }
else
  # Interactive mode.
  loop do
    print "Enter the path to a Ruby file to review (or 'quit' to exit):\n> "
    $stdout.flush

    path = $stdin.gets.to_s.strip
    break if path.downcase == "quit" || path.empty?

    run_review(app, path)

    puts
    print "Review another file? (y/n) > "
    $stdout.flush
    break unless $stdin.gets.to_s.strip.downcase == "y"

    puts
  end
end

puts "\nDone."
