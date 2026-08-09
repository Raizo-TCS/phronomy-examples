#!/usr/bin/env ruby
# frozen_string_literal: true

# Smoke test for 0.15.0 Tool Approval API (tool_approval_policy / approve())
#
# Run with:
#   PHRONOMY_MODEL="openai/gpt-oss-20b" \
#   PHRONOMY_BASE_URL="http://192.168.122.1:1234/v1" \
#   PHRONOMY_API_KEY="lm-studio" \
#   PHRONOMY_PROVIDER="openai" \
#   bundle exec ruby test_approval_lmstudio.rb

require_relative "shared/llm_config"
require "phronomy"

# ---------------------------------------------------------------------------
# Tool: requires human approval before execution
# ---------------------------------------------------------------------------
class DeleteFileTool < Phronomy::Agent::Context::Capability::Base
  tool_name "delete_file"
  description "Deletes a file from the filesystem. DANGEROUS — requires human approval."
  param :path, type: :string, desc: "File path to delete"
  requires_approval true

  def execute(path:)
    "[DRY RUN] File '#{path}' would be deleted."
  end
end

# ---------------------------------------------------------------------------
# Agent: tool_approval_policy suspends on requires_approval tools
# ---------------------------------------------------------------------------
class FileManagerAgent < Phronomy::Agent::Base
  model        LLMConfig::MODEL
  provider     LLMConfig::PROVIDER
  instructions "You are a file management assistant. " \
               "When asked to delete a file, call the delete_file tool."
  tools DeleteFileTool => nil
end

# ---------------------------------------------------------------------------
# Flow
# ---------------------------------------------------------------------------
agent = FileManagerAgent.new

# tool_approval_policy and on_tool_approval_required are instance methods
agent.tool_approval_policy do |_request|
  # :require_approval => suspend and wait for human decision
  :require_approval
end

agent.on_tool_approval_required do |request|
  puts "  [APPROVAL REQUIRED]"
  puts "    request.id           : #{request.id}"
  puts "    agent_invocation_id  : #{request.agent_invocation_id}"
  request.items.each do |item|
    puts "    tool_name  : #{item.tool_name}"
    puts "    arguments  : #{item.arguments.inspect}"
  end
end

puts "=== Tool Approval API Smoke Test (0.15.0) ==="
puts

# Step 1: invoke — should suspend
puts "Step 1: invoke('Please delete /tmp/old_data.txt')"
result = agent.invoke("Please delete /tmp/old_data.txt")

unless result[:suspended]
  puts "UNEXPECTED: agent did NOT suspend (model may not have called the tool)"
  puts "Output: #{result[:output]}"
  exit 1
end

agent_invocation_id  = result[:agent_invocation_id]
approval_req         = result[:approval_request]
approval_request_id  = approval_req.id

puts "  suspended            : #{result[:suspended]}"
puts "  agent_invocation_id  : #{agent_invocation_id}"
result[:approval_request].items.each do |item|
  puts "  tool_name            : #{item.tool_name}"
  puts "  arguments            : #{item.arguments.inspect}"
end
puts

# Step 2: approve — should resume and complete
puts "Step 2: approve(agent_invocation_id, approval_request_id: ..., approved: true)"
final = agent.approve(agent_invocation_id, approval_request_id: approval_request_id, approved: true)

puts
puts "  output: #{final[:output]}"
puts

if final[:output].to_s.length >= 5
  puts "=== PASSED ==="
else
  puts "=== FAILED: output too short ==="
  exit 1
end
