#!/usr/bin/env ruby
# frozen_string_literal: true

# 13 MCP HTTP Tool
#
# Demonstrates McpTool::HttpTransport — wrapping an MCP server tool exposed
# over HTTP/JSON-RPC. A minimal WEBrick-based MCP server is started in-process
# via a background Thread, then torn down in an ensure block.

require_relative "../shared/llm_config"
require "phronomy"
require_relative "mcp_server"

PORT = 19876

server = McpHttpServer.new(PORT)
server_thread = Thread.new { server.start }
sleep 0.3

begin
  puts "=== MCP HTTP Tool Example ==="
  puts "MCP server running at http://localhost:#{PORT}/mcp"
  puts

  greet_tool = Phronomy::Tool::McpTool.from_server(
    "http://localhost:#{PORT}/mcp",
    tool_name: "greet"
  )

  class GreetingAgent < Phronomy::Agent::Base
    model LLMConfig::MODEL
    provider LLMConfig::PROVIDER
    instructions "You are a friendly assistant. Use the greet tool to greet people by name."
  end

  GreetingAgent.tools(greet_tool)

  query = "Please greet Alice using the greet tool."
  puts "Query: #{query}"
  puts
  puts "--- Agent Response ---"

  result = GreetingAgent.new.invoke(query)
  puts result[:output]
ensure
  server.shutdown
  server_thread.join(5)
end
