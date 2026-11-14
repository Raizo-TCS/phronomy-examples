# frozen_string_literal: true

# 22 Shared State -- Collaborative Code Review Team
#
# Three specialist agents collaborate via Phronomy::MultiAgent::SharedState to
# produce a multi-perspective review. Each member has its own Agent identity,
# while the team exposes shared-store tools for explicit coordination.

require_relative "team"

target_dir = ARGV[0] || File.expand_path("./data", __dir__)

puts "=== Shared State Code Review Example ==="
puts "Target : #{target_dir}"

# This prompt is application-owned HITL. For framework-owned Agent tool
# approval/suspension, see 04_interrupt_resume.
DirectoryAccess.ask_user!(target_dir)

result = CodeReviewTeam.new.invoke("Review the Ruby source files in: #{target_dir}")

puts result[:output][:report]
puts
puts "-" * 50
puts "Cycles completed : #{result[:cycles]}"
puts "Terminated by    : #{result[:terminated_by]}"
puts "Total findings   : #{result[:output][:count]}"
