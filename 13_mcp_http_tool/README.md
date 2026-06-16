# 13 MCP HTTP Tool

Demonstrates `Phronomy::Tools::Mcp` over HTTP/JSON-RPC transport.

## Purpose

Show how to connect to an MCP server that communicates via HTTP rather than
stdio. A minimal WEBrick-based MCP server is started in-process, exposed on
a local port, and torn down after the agent finishes.

## Phronomy Features

| Feature | Usage |
|---------|-------|
| `Phronomy::Tools::Mcp.from_server("http://...", tool_name:)` | Wraps a single named tool from an HTTP MCP server |
| `tools` DSL | Registers the MCP tool on the agent class |

## MCP Server (`mcp_server.rb`)

Implements two JSON-RPC endpoints:

| Method | Parameters | Returns |
|--------|------------|---------|
| `tools/list` | — | Tool definition for `greet` |
| `tools/call` | `name: String` | `"Hello, <name>! (via MCP HTTP)"` |

The server listens on port `19876` and is started in a background thread,
then shut down in an `ensure` block.

## How to Run

```bash
bundle exec ruby 13_mcp_http_tool/run.rb
```

## Expected Output (approximate)

```
=== MCP HTTP Tool Example ===
MCP server running at http://localhost:19876/mcp

Query: Please greet Alice using the greet tool.

--- Agent Response ---
Hello, Alice! (via MCP HTTP)
```
