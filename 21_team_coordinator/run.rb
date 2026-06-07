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

# ---------------------------------------------------------------------------
# Worker: writes one blog section per invocation, accumulating style context
# ---------------------------------------------------------------------------
class BlogSectionWriter < Phronomy::Agent::Base
  model        LLMConfig::MODEL
  provider     LLMConfig::PROVIDER
  instructions <<~INST
    You are a concise technical blog writer for Ruby developers.
    Write the requested blog section clearly and engagingly.
    Keep each section under 150 words.
    When you have written previous sections, maintain a consistent tone and
    refer back to earlier content where appropriate.
  INST
end

# ---------------------------------------------------------------------------
# Team: coordinator decomposes the topic, two workers share the writing load
# ---------------------------------------------------------------------------
class BlogWritingTeam < Phronomy::MultiAgent::TeamCoordinator
  coordinator_model        LLMConfig::MODEL
  coordinator_provider     LLMConfig::PROVIDER
  coordinator_instructions <<~INST
    You are a blog editor. Your job is to plan the structure of a technical
    blog post on the given topic.
    Break the post into 4-5 sections (e.g. Introduction, Core Concepts,
    Code Example, Practical Tips, Conclusion).
    For each section, call enqueue_task with a description like:
      "Write the [Section Name] section. Cover: <key points>"
    Call finalize when all sections are enqueued.
  INST

  pool size: 2, agent: BlogSectionWriter

  aggregate do |assignments|
    {
      sections: assignments.map { |a|
        {worker: a[:worker], description: a[:task][:description], content: a[:result]}
      }
    }
  end
end

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
TOPIC = "Concurrency in Ruby: Threads, Fibers, and Ractors"

puts "=== 21 Team Coordinator ===\n\n"
puts "Topic: \"#{TOPIC}\"\n\n"
puts "[Coordinator] Planning blog sections...\n\n"

result = OutputValidator.validate(
  "team coordinator produces 4+ blog sections",
  check: ->(r) { r[:sections].size >= 4 && r[:sections].all? { |s| s[:content].to_s.length >= 50 } }
) {
  team = BlogWritingTeam.new
  team.stream(TOPIC) do |event|
    label = event[:type] == :task_completed ? "\u2713" : "\u2717"
    desc  = event[:task][:description].split(".").first
    snippet = (event[:result] || event[:error]&.message || "").gsub(/\s+/, " ").slice(0, 80)
    puts "#{label} [Worker #{event[:worker]}] #{desc}"
    puts "  #{snippet}..."
    puts
  end
}

puts "\n=== Final Blog Post: #{result[:sections].size} sections ===\n\n"

result[:sections].each_with_index do |s, i|
  puts "--- Section #{i + 1} [Worker #{s[:worker]}] ---"
  puts s[:description]
  puts
  puts s[:content]
  puts
end
