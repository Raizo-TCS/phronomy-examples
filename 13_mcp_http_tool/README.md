# 13 MCP HTTP Tool

Demonstrates `Phronomy::Tool::McpTool` over HTTP/JSON-RPC transport.

## Purpose

Show how to connect to an MCP server that communicates via HTTP rather than
stdio. A minimal WEBrick-based MCP server is started in-process, exposed on
a local port, and torn down after the agent finishes.

## Phronomy Features

| Feature | Usage |
|---------|-------|
| `Phronomy::Tool::McpTool.from_server("http://...", tool_name:)` | HTTP transport |
| `McpTool::HttpTransport` | JSON-RPC over HTTP (`application/json`) |
| `tools` DSL | Registers the HTTP MCP tool on the agent |

## MCP Server (`mcp_server.rb`)

Implements two JSON-RPC endpoints:

| Method | Parameters | Returns |
|--------|------------|---------|
| `tools/list` | — | Tool definition for `greet` |
| `tools/call` | `name: String` | `"Hello, <name>! (via MCP HTTP)"` |

## How to Run

```bash
bundle exec ruby 13_mcp_http_tool/run.rb
```

## Expected Output (approximate)

```
=== MCP HTTP Tool Example ===

Query: Please greet Alice using the tool.

--- Agent Response ---
Hello, Alice! (via MCP HTTP)
```
