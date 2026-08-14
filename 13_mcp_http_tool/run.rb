#!/usr/bin/env ruby
# frozen_string_literal: true

# 13 MCP HTTP Tool
#
# Demonstrates Phronomy::Tools::Mcp over HTTP with two features:
#
#   headers:        — pass custom HTTP headers (e.g. Authorization, X-Api-Key)
#                     to every request (tool discovery + tool execution).
#   execution_mode  — MCP tools default to :offloaded (OffloadPool).
#                     This keeps the Phronomy EventLoop free even when an MCP
#                     call takes a long time.
#
# Part 2 proves the non-blocking behaviour: two agents each invoke a slow MCP
# tool via invoke_async. The MCP waits can overlap instead of occupying the
# Runtime/EventLoop dispatch path.

require_relative "../shared/llm_config"
require_relative "../shared/output_validator"
require "phronomy"
require_relative "mcp_server"

PORT = 19_876
API_KEY = "demo-key-123"
SLOW_MS = 800

server = McpHttpServer.new(PORT)
server_thread = Thread.new { server.start }
sleep 0.3

begin
  puts "=== MCP HTTP Tool Example ==="
  puts "MCP server at http://localhost:#{PORT}/mcp  (slow mode: #{SLOW_MS} ms)"
  puts

  greet_tool = Phronomy::Tools::Mcp.from_server(
    "http://localhost:#{PORT}/mcp",
    tool_name: "greet",
    headers: {"X-Api-Key" => API_KEY}
  )

  class GreetingAgent < Phronomy::Agent::Base
    agent_definition id: "example-13-greeting-agent", version: 2

    model LLMConfig::MODEL
    provider LLMConfig::PROVIDER
    instructions "You are a friendly assistant. Use the greet tool to greet " \
                 "people by name. Pass delay_ms: #{SLOW_MS} to the tool."

    def initialize(...)
      super(...)
      # MCP tools require approval by default; allow them in this demo.
      tool_approval_policy { :allow }
    end
  end

  GreetingAgent.tools(greet_tool => nil)

  puts "--- Part 1: single synchronous call ---"
  result = OutputValidator.validate(
    "MCP HTTP agent greets Alice",
    check: ->(r) { r[:output].downcase.include?("alice") || r[:output].length >= 10 }
  ) { GreetingAgent.new.invoke("Please greet Alice using the greet tool.") }
  puts result[:output]
  puts

  puts "--- Part 2: parallel vs sequential (#{SLOW_MS} ms MCP delay each) ---"

  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  GreetingAgent.new.invoke("Please greet Charlie using the greet tool.")
  GreetingAgent.new.invoke("Please greet Diana using the greet tool.")
  seq_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round
  puts "Sequential: #{seq_ms} ms"

  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  task_a = GreetingAgent.new.invoke_async("Please greet Alice using the greet tool.")
  task_b = GreetingAgent.new.invoke_async("Please greet Bob using the greet tool.")
  result_a = task_a.wait_result
  result_b = task_b.wait_result
  par_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round

  puts "Parallel:   #{par_ms} ms"
  puts "Agent A: #{result_a[:output]}"
  puts "Agent B: #{result_b[:output]}"
  puts

  if par_ms < seq_ms
    puts "✓ Parallel was faster (#{seq_ms - par_ms} ms saved)."
    puts "  The MCP waits overlapped instead of blocking Runtime dispatch."
  else
    puts "~ No speedup observed (the LLM server may serialize concurrent requests)."
  end
ensure
  server.shutdown
  server_thread.join(5)
end
