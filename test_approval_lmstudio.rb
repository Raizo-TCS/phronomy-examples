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

require "thread"
require_relative "shared/llm_config"
require "phronomy"

# ---------------------------------------------------------------------------
# Tool: requires human approval before execution
# ---------------------------------------------------------------------------
class DeleteFileTool < Phronomy::Tool::Base
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
approval_requests = Queue.new
agent = FileManagerAgent.new(
  on_event: ->(event) {
    next unless event.type == :approval_required

    request = event.payload.fetch(:request)
    puts "  [APPROVAL REQUIRED]"
    puts "    request.id : #{request.id}"
    request.items.each do |item|
      puts "    tool_name  : #{item.tool_name}"
      puts "    arguments  : #{item.arguments.inspect}"
      puts "    facts      : #{item.facts.inspect}"
    end
    approval_requests << request
  }
)

agent.tool_approval_policy do |_request|
  :require_approval
end

puts "=== Tool Approval API Smoke Test ==="
puts

# Step 1: start asynchronously. Approval suspension is nonterminal, so the
# original Task must remain pending while the application handles the request.
puts "Step 1: invoke_async('Please delete /tmp/old_data.txt')"
original_task = agent.invoke_async("Please delete /tmp/old_data.txt")
approval_request = approval_requests.pop
execution_id = approval_request.execution_id
approval_request_id = approval_request.id

puts "  suspended            : true"
puts "  original_task.done?  : #{original_task.done?}"
puts "  execution_id         : #{execution_id}"
puts "  approval_request_id  : #{approval_request_id}"
approval_request.items.each do |item|
  puts "  tool_name            : #{item.tool_name}"
  puts "  arguments            : #{item.arguments.inspect}"
end
puts

if original_task.done?
  puts "UNEXPECTED: original Agent Task settled while approval was still pending"
  exit 1
end

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
original_result = original_task.wait_result

unless original_result[:execution_id] == final[:execution_id]
  puts "UNEXPECTED: approval result and original Task refer to different executions"
  exit 1
end

puts
puts "  live owner:           #{owner.class}"
puts "  original_task.done? : #{original_task.done?}"
puts "  output:               #{final[:output]}"
puts

if final[:output].to_s.length >= 5
  puts "=== PASSED ==="
else
  puts "=== FAILED: output too short ==="
  exit 1
end
