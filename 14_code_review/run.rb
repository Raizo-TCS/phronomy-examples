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

# ---- Main loop ----

app = build_pipeline

puts "=== AI Code Review Pipeline ==="
puts

loop do
  print "Enter the path to a Ruby file to review (or 'quit' to exit):\n> "
  $stdout.flush

  path = $stdin.gets.to_s.strip
  break if path.downcase == "quit" || path.empty?

  # InputGuardrail: validate the supplied path.
  begin
    INPUT_GUARDRAIL.run!(path)
  rescue Phronomy::GuardrailError => e
    puts "[InputGuardrail] Rejected: #{e.message}"
    puts
    next
  end

  source_code = File.read(path)

  # Phase 1: load, split, and run parallel reviews.
  # The graph halts before :improve due to interrupt_before.
  puts "\n[Pipeline] Starting review..."
  puts "[ParallelNode] Running Security / Performance / Readability reviews concurrently..."
  state = app.invoke({ file_path: path, source_code: source_code })

  # Display the collected review findings.
  display_reviews(state.reviews)

  # Interrupt/Resume: ask the user which area to improve.
  priority = ask_priority
  puts "\n[Pipeline] Resuming with priority: #{priority}"

  # Phase 2: improve, evaluate, and finish.
  state = app.resume(state: state, input: { priority: priority })

  # Display eval scores.
  display_eval_scores(state.eval_scores)

  puts
  print "Review another file? (y/n) > "
  $stdout.flush
  break unless $stdin.gets.to_s.strip.downcase == "y"

  puts
end

puts "\nDone."
