#!/usr/bin/env ruby
# frozen_string_literal: true

# 08 MCP Tool
#
# Demonstrates wrapping an MCP (Model Context Protocol) server's tool with
# Phronomy::Tools::Mcp and exposing it to an Agent.
# The bundled mcp_server.rb provides a single `list_files` tool over stdio.

require_relative "../shared/llm_config"
require_relative "../shared/output_validator"
require "phronomy"

server_command = "ruby #{File.join(__dir__, "mcp_server.rb")}"

list_files_tool = Phronomy::Tools::Mcp.from_server(
  "stdio://#{server_command}",
  tool_name: "list_files"
)

class FileExplorerAgent < Phronomy::Agent::Base
  agent_definition id: "example-08-file-explorer-agent", version: 2

  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  instructions "You are a file system assistant. " \
               "Follow the user's instructions and use the list_files tool " \
               "to list the files in a directory concisely."

  def initialize(...)
    super(...)
    # MCP tools require approval by default; allow them in this demo.
    tool_approval_policy { :allow }
  end
end

# Current Phronomy tool registration uses ToolClass => alias_or_nil.
FileExplorerAgent.tools(list_files_tool => nil)

puts "=== MCP Tool Example ==="
puts "Starting MCP server..."

query = "List the files in the current directory ('.')."
puts "Query: #{query}"
puts
puts "--- Agent Response ---"

begin
  result = OutputValidator.validate(
    "agent lists files via MCP tool",
    check: ->(r) { r[:output].length >= 20 }
  ) { FileExplorerAgent.new.invoke(query) }
  puts result[:output]
ensure
  list_files_tool.close
end
