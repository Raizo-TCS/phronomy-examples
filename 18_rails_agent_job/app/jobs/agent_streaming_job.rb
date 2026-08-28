# frozen_string_literal: true

# Application-owned ActiveJob adapter for Phronomy streaming.
#
# Phronomy exposes Agent#stream; Rails integration composes that public API with
# the application's own queue and ActionCable conventions rather than depending
# on a framework-specific Rails adapter.
class AgentStreamingJob < ApplicationJob
  queue_as :default

  AGENTS = {
    "DemoAgent" => DemoAgent
  }.freeze

  def perform(agent_class_name, input, stream:)
    agent_class = AGENTS.fetch(agent_class_name) do
      raise ArgumentError, "unsupported agent_class_name: #{agent_class_name}"
    end

    error_broadcast = false

    agent = agent_class.new(
      on_event: ->(event) {
        message = case event.type
        when :token
          {type: "token", content: event.payload[:content].to_s}
        when :tool_call
          {
            type: "tool_call",
            tool: event.payload[:tool_call]&.name.to_s
          }
        when :tool_result
          {type: "tool_result"}
        when :done
          {
            type: "done",
            output: event.payload[:output].to_s
          }
        when :error
          error_broadcast = true
          {
            type: "error",
            message: event.payload[:error]&.message.to_s
          }
        end

        ActionCable.server.broadcast(stream, message) if message
      }
    )
    agent.stream(input.to_s)
  rescue => e
    ActionCable.server.broadcast(
      stream,
      {type: "error", message: e.message}
    ) unless error_broadcast

    raise
  end
end
