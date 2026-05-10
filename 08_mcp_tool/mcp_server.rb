#!/usr/bin/env ruby
# frozen_string_literal: true

# Minimal MCP-style stdio JSON-RPC server providing a single tool:
# `list_files` — returns the entries of a directory as a newline string.
#
# Protocol: line-delimited JSON-RPC 2.0 on stdin/stdout.
# Methods supported:
#   - initialize       (returns a stub server info)
#   - tools/list       (returns the tool schema)
#   - tools/call       (executes the named tool)

require "json"

$stdout.sync = true

TOOL_DEFS = [
  {
    name: "list_files",
    description: "Returns the entries of the specified directory as a newline-separated string.",
    inputSchema: {
      type: "object",
      properties: {
        path: {type: "string", description: "Path to the target directory"}
      },
      required: ["path"]
    }
  }
].freeze

def handle(request)
  id = request["id"]
  case request["method"]
  when "initialize"
    {
      jsonrpc: "2.0", id: id,
      result: {protocolVersion: "0.1", serverInfo: {name: "phronomy-example-mcp", version: "0.0.1"}}
    }
  when "tools/list"
    {jsonrpc: "2.0", id: id, result: {tools: TOOL_DEFS}}
  when "tools/call"
    name = request.dig("params", "name")
    args = request.dig("params", "arguments") || {}
    case name
    when "list_files"
      path = args["path"] || "."
      begin
        entries = Dir.children(path).sort.join("\n")
        {jsonrpc: "2.0", id: id, result: {content: [{type: "text", text: entries}]}}
      rescue => e
        {jsonrpc: "2.0", id: id, error: {code: -32000, message: e.message}}
      end
    else
      {jsonrpc: "2.0", id: id, error: {code: -32601, message: "Unknown tool: #{name}"}}
    end
  else
    {jsonrpc: "2.0", id: id, error: {code: -32601, message: "Method not found: #{request["method"]}"}}
  end
end

while (line = $stdin.gets)
  line = line.strip
  next if line.empty?
  begin
    request = JSON.parse(line)
  rescue JSON::ParserError => e
    $stdout.puts({jsonrpc: "2.0", id: nil, error: {code: -32700, message: "Parse error: #{e.message}"}}.to_json)
    next
  end
  $stdout.puts(handle(request).to_json)
end
