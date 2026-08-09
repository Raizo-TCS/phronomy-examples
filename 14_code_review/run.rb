#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../shared/llm_config"
require "phronomy"
require_relative "guardrails"
require_relative "pipeline"

Phronomy.configure do |config|
  config.tracer = ConsoleTracer.new
end

INPUT_GUARDRAIL = FileInputGuardrail.new
CLI_PATH = ARGV[0]
CLI_PRIORITY = ARGV[1]

def display_reviews(reviews)
  puts
  puts "=" * 50
  puts "Review Results"
  puts "=" * 50
  {
    security: "Security",
    performance: "Performance",
    readability: "Readability",
    abstraction: "Abstraction Consistency"
  }.each do |key, label|
    text = reviews[key].to_s.strip
    next if text.empty?
    puts "\n#{label}:"
    text.each_line { |line| puts "  #{line.chomp}" }
  end
  puts "=" * 50
end

def ask_priority
  puts "\nWhich area would you like to improve?"
  puts "  1) security"
  puts "  2) performance"
  puts "  3) readability"
  puts "  4) abstraction"
  print "> "
  $stdout.flush

  case $stdin.gets.to_s.strip
  when "1", "security" then "security"
  when "2", "performance" then "performance"
  when "3", "readability" then "readability"
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

def run_review(app, path, priority_override = nil)
  begin
    INPUT_GUARDRAIL.call(path)
  rescue Phronomy::FilterBlockError => e
    puts "[InputFilter] Rejected: #{e.message}"
    return
  end

  source_code = File.read(path)
  puts "\n[Pipeline] Starting review..."
  state = app.invoke({file_path: path, source_code: source_code})
  display_reviews(state.reviews)

  priority = priority_override || ask_priority
  puts "\n[Pipeline] Proceeding with priority: #{priority}"
  state = app.send_event(state: state, event: :proceed, input: {priority: priority})
  display_eval_scores(state.eval_scores)
end

app = build_pipeline
puts "=== AI Code Review Pipeline ==="
puts

if CLI_PATH
  paths = File.directory?(CLI_PATH) ? Dir.glob(File.join(CLI_PATH, "*.rb")).sort : [CLI_PATH]
  paths.each { |path| run_review(app, path, CLI_PRIORITY) }
else
  loop do
    print "Enter the path to a Ruby file to review (or 'quit' to exit):\n> "
    $stdout.flush
    path = $stdin.gets.to_s.strip
    break if path.empty? || path.downcase == "quit"
    run_review(app, path)
    puts
    print "Review another file? (y/n) > "
    $stdout.flush
    break unless $stdin.gets.to_s.strip.downcase == "y"
  end
end

puts "\nDone."
