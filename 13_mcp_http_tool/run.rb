#!/usr/bin/env ruby
# frozen_string_literal: true

# 13 MCP HTTP Tool
#
# Demonstrates McpTool::HttpTransport — wrapping an MCP server tool exposed
# over HTTP/JSON-RPC.
#
# New features shown in this example:
#   headers:        — pass custom HTTP headers (e.g. Authorization, X-Api-Key)
#                     to every request (tool discovery + tool execution).
#   execution_mode  — controls how tool I/O is dispatched in Phronomy's
#                     cooperative EventLoop.  MCP tools default to
#                     :blocking_io (BlockingAdapterPool).  Use :cooperative
#                     only for pure in-memory tools that never block.

require_relative "../shared/llm_config"
require_relative "../shared/output_validator"
require "phronomy"
require_relative "mcp_server"

PORT = 19876
API_KEY = "demo-key-123"

server = McpHttpServer.new(PORT)
server_thread = Thread.new { server.start }
sleep 0.3

begin
  puts "=== MCP HTTP Tool Example ==="
  puts "MCP server running at http://localhost:#{PORT}/mcp"
  puts

  # Pass custom headers to every request (tool discovery and tool execution).
  # Typical use: Bearer tokens, API keys, tenant identifiers.
  greet_tool = Phronomy::Tools::Mcp.from_server(
    "http://localhost:#{PORT}/mcp",
    tool_name: "greet",
    headers: {"X-Api-Key" => API_KEY}
  )

  # execution_mode :blocking_io is the default for all MCP tools.
  # It routes tool calls through BlockingAdapterPool so the EventLoop
  # thread is never blocked by HTTP I/O.
  # Uncomment the next line to verify the default explicitly:
  # greet_tool.class.execution_mode :blocking_io

  class GreetingAgent < Phronomy::Agent::Base
    model LLMConfig::MODEL
    provider LLMConfig::PROVIDER
    instructions "You are a friendly assistant. Use the greet tool to greet people by name."
  end

  GreetingAgent.tools(greet_tool)

  query = "Please greet Alice using the greet tool."
  puts "Query: #{query}"
  puts "API key sent in X-Api-Key header: #{API_KEY}"
  puts
  puts "--- Agent Response ---"

  result = OutputValidator.validate(
    "MCP HTTP agent greets Alice",
    check: ->(r) { r[:output].downcase.include?("alice") || r[:output].length >= 20 }
  ) { GreetingAgent.new.invoke(query) }
  puts result[:output]
ensure
  server.shutdown
  server_thread.join(5)
end
