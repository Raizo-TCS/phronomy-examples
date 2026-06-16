# 08 MCP Tool (stdio)

Demonstrates wrapping a stdio MCP server's tool with `Phronomy::Tools::Mcp`.

## Purpose

Show how to launch a local MCP server as a subprocess and expose one of its
tools to an `Agent::Base` via the stdio transport.

## Phronomy Features

| Feature | Usage |
|---------|-------|
| `Phronomy::Tools::Mcp.from_server("stdio://...", tool_name:)` | Wraps a named tool from a stdio MCP server |
| `tools` DSL | Registers the MCP tool on the agent at runtime |

## MCP Server (`mcp_server.rb`)

Provides a single `list_files` tool that lists entries in a given directory.

## How to Run

```bash
bundle exec ruby 08_mcp_tool/run.rb
```

## Expected Output (approximate)

```
=== MCP Tool Example ===
Starting MCP server...
Query: List the files in the current directory ('.').

--- Agent Response ---
The current directory contains: run.rb, mcp_server.rb, ...
```
