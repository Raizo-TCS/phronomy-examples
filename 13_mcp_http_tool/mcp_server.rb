# frozen_string_literal: true

# Minimal WEBrick-based MCP HTTP server for the 13_mcp_http_tool example.
# Provides a single tool: `greet` — returns a greeting string for a given name.
# Implements the JSON-RPC 2.0 subset used by the MCP protocol.

require "webrick"
require "json"

class McpHttpServer
  TOOL_DEF = {
    name: "greet",
    description: "Returns a greeting for the given name. " \
                 "Accepts an optional delay_ms to simulate slow MCP responses.",
    inputSchema: {
      type: "object",
      properties: {
        name: {type: "string", description: "Name of the person to greet"},
        delay_ms: {type: "integer", description: "Optional response delay in milliseconds (default: 0)"}
      },
      required: ["name"]
    }
  }.freeze

  def initialize(port)
    @server = WEBrick::HTTPServer.new(
      Port: port,
      Logger: WEBrick::Log.new(File.open(File::NULL, "w")),
      AccessLog: []
    )
    @server.mount_proc("/mcp") do |req, res|
      handle(req, res)
    end
  end

  def start
    @server.start
  end

  def shutdown
    @server.shutdown
  end

  private

  def handle(req, res)
    body = JSON.parse(req.body)
    # Extract custom headers so tools/call can reflect them in the response.
    api_key = req["X-Api-Key"]
    result = dispatch(body["method"], body.fetch("params", {}), api_key: api_key)
    res.status = 200
    res["Content-Type"] = "application/json"
    res.body = JSON.generate(jsonrpc: "2.0", id: body["id"], result: result)
  rescue => e
    res.status = 500
    res["Content-Type"] = "application/json"
    res.body = JSON.generate(
      jsonrpc: "2.0",
      id: nil,
      error: {code: -32603, message: e.message}
    )
  end

  def dispatch(method, params, api_key: nil)
    case method
    when "tools/list"
      {tools: [TOOL_DEF]}
    when "tools/call"
      name = params.dig("arguments", "name") || "World"
      delay_ms = params.dig("arguments", "delay_ms").to_i
      sleep(delay_ms / 1000.0) if delay_ms > 0
      auth_note = api_key ? " [key=#{api_key}]" : ""
      {content: [{type: "text", text: "Hello, #{name}! (via MCP HTTP)#{auth_note}"}]}
    else
      raise "Unknown method: #{method}"
    end
  end
end
