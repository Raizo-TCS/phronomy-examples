# frozen_string_literal: true

# 21 Team Coordinator
#
# Demonstrates MultiAgent::TeamCoordinator — the "Agent teams" coordination pattern.
#
# A coordinator LLM agent breaks a blog topic into sections (enqueue_task),
# then a pool of two worker agents writes each section. Workers carry forward
# their conversation history across assignments so tone and style remain
# consistent throughout the post.

require_relative "../shared/llm_config"
require_relative "../shared/output_validator"
require "phronomy"

require_relative "agents"

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
TOPIC = "Concurrency in Ruby: Threads, Fibers, and Ractors"

puts "=== 21 Team Coordinator ===\n\n"
puts "Topic: \"#{TOPIC}\"\n\n"
puts "[Coordinator] Planning blog sections...\n\n"

result = OutputValidator.validate(
  "team coordinator produces 4+ blog sections",
  check: ->(r) { r.fetch("sections").size >= 4 && r.fetch("sections").all? { |s| s.fetch("content").to_s.length >= 50 } }
) {
  team = BlogWritingTeam.new
  team.stream(TOPIC) do |event|
    label = event[:type] == :task_completed ? "\u2713" : "\u2717"
    desc  = event[:task][:description].split(".").first
    snippet = (event[:result] || event[:error]&.fetch("message", nil) || "").gsub(/\s+/, " ").slice(0, 80)
    puts "#{label} [Worker #{event[:worker]}] #{desc}"
    puts "  #{snippet}..."
    puts
  end
}

puts "\n=== Final Blog Post: #{result.fetch("sections").size} sections ===\n\n"

result.fetch("sections").each_with_index do |s, i|
  puts "--- Section #{i + 1} [Worker #{s.fetch("worker")}] ---"
  puts s.fetch("description")
  puts
  puts s.fetch("content")
  puts
end
