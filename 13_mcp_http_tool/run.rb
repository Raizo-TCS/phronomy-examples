#!/usr/bin/env ruby
# frozen_string_literal: true

# 13 MCP HTTP Tool
#
# Demonstrates McpTool::HttpTransport with two new features:
#
#   headers:        — pass custom HTTP headers (e.g. Authorization, X-Api-Key)
#                     to every request (tool discovery + tool execution).
#   execution_mode  — MCP tools default to :blocking_io (BlockingAdapterPool).
#                     This keeps the Phronomy EventLoop free even when an MCP
#                     call takes a long time.
#
# Part 2 of this example proves the non-blocking behaviour: two agents each
# invoke a slow MCP tool (800 ms) via invoke_async.  Because both run
# concurrently on the EventLoop, total wall-clock time is ~800 ms, not ~1600 ms.

require_relative "../shared/llm_config"
require_relative "../shared/output_validator"
require "phronomy"
require_relative "mcp_server"

PORT = 19876
API_KEY = "demo-key-123"
SLOW_MS = 800  # simulated MCP response delay in milliseconds

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
    model LLMConfig::MODEL
    provider LLMConfig::PROVIDER
    instructions "You are a friendly assistant. Use the greet tool to greet " \
                 "people by name. Pass delay_ms: #{SLOW_MS} to the tool."
  end

  GreetingAgent.tools(greet_tool)

  # ── Part 1: baseline single call ─────────────────────────────────────────
  puts "--- Part 1: single synchronous call ---"
  result = OutputValidator.validate(
    "MCP HTTP agent greets Alice",
    check: ->(r) { r[:output].downcase.include?("alice") || r[:output].length >= 10 }
  ) { GreetingAgent.new.invoke("Please greet Alice using the greet tool.") }
  puts result[:output]
  puts

  # ── Part 2: parallel vs sequential comparison ────────────────────────────
  # Each agent calls the slow MCP tool (SLOW_MS ms).
  # Sequential: Agent A finishes, then Agent B starts → ~2 × agent_time
  # Parallel:   Both run concurrently via invoke_async → MCP sleeps overlap
  puts "--- Part 2: parallel vs sequential (#{SLOW_MS} ms MCP delay each) ---"

  # Sequential baseline
  t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  GreetingAgent.new.invoke("Please greet Charlie using the greet tool.")
  GreetingAgent.new.invoke("Please greet Diana using the greet tool.")
  seq_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round
  puts "Sequential: #{seq_ms} ms"

  # Parallel via invoke_async — MCP sleeps run concurrently
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
    puts "  The #{SLOW_MS} ms MCP sleeps overlapped — EventLoop was NOT blocked."
  else
    puts "~ No speedup observed (LLM server may be serialising concurrent requests)."
  end
ensure
  server.shutdown
  server_thread.join(5)
end
