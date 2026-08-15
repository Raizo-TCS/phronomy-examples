#!/usr/bin/env ruby
# frozen_string_literal: true

# Manual LM Studio smoke test for the current Tool Approval API.
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
  agent_definition id: "manual-lmstudio-file-manager", version: 1

  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  instructions "You are a file management assistant. " \
               "When asked to delete a file, call the delete_file tool."
  tools(DeleteFileTool => nil)
end

# ---------------------------------------------------------------------------
# Flow
# ---------------------------------------------------------------------------
agent = FileManagerAgent.new

agent.tool_approval_policy do |_request|
  :require_approval
end

agent.on_tool_approval_required do |request|
  puts "  [APPROVAL REQUIRED]"
  puts "    request.id : #{request.id}"
  request.items.each do |item|
    puts "    tool_name  : #{item.tool_name}"
    puts "    arguments  : #{item.arguments.inspect}"
    puts "    facts      : #{item.facts.inspect}"
  end
end

puts "=== Tool Approval API Smoke Test ==="
puts

# Step 1: invoke — should suspend.
puts "Step 1: invoke('Please delete /tmp/old_data.txt')"
result = agent.invoke("Please delete /tmp/old_data.txt")

unless result[:suspended]
  puts "UNEXPECTED: agent did NOT suspend (model may not have called the tool)"
  puts "Output: #{result[:output]}"
  exit 1
end

execution_id = result.fetch(:execution_id)
approval_request = result.fetch(:approval_request)
approval_request_id = approval_request.id

puts "  suspended            : #{result[:suspended]}"
puts "  execution_id         : #{execution_id}"
puts "  approval_request_id  : #{approval_request_id}"
approval_request.items.each do |item|
  puts "  tool_name            : #{item.tool_name}"
  puts "  arguments            : #{item.arguments.inspect}"
end
puts

# Step 2: resolve the existing live owner, then approve.
# execution_id is routing identity, not an authorization token; a real
# application must authorize the caller before approving the request.
puts "Step 2: live_for_execution(execution_id) -> approve(...)"
owner = FileManagerAgent.live_for_execution(execution_id)

unless owner.equal?(agent)
  puts "UNEXPECTED: live owner is not the original Agent object"
  exit 1
end

final = owner.approve(
  execution_id,
  approval_request_id: approval_request_id,
  approved: true
)

puts
puts "  live owner: #{owner.class}"
puts "  output: #{final[:output]}"
puts

if final[:output].to_s.length >= 5
  puts "=== PASSED ==="
else
  puts "=== FAILED: output too short ==="
  exit 1
end
