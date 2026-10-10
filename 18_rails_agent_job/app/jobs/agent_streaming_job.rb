# frozen_string_literal: true

require "phronomy/integrations/ordered_event_delivery"

# The app owns payloads, authorization, destination and token coalescing.
class AgentStreamingJob < ApplicationJob
  queue_as :default

  AGENTS = {"DemoAgent" => DemoAgent}.freeze

  def perform(agent_class_name, input, stream:)
    sender = ->(payload) {
      Rails.application.executor.wrap do
        ActionCable.server.broadcast(stream, payload)
      end
    }
    Phronomy::Integrations::OrderedEventDelivery.open(
      capacity: 256, batch_size: 32, flush_timeout: 30,
      deliver: sender, prepare_batch: TokenEventBatch.method(:call)
    ) do |delivery|
      error_notified = false
      begin
        agent_class = AGENTS.fetch(agent_class_name) do
          raise ArgumentError, "unsupported agent_class_name: #{agent_class_name}"
        end
        agent = agent_class.new(on_event: ->(event) {
          payload = event_payload(event)
          if payload
            delivery.publish(payload)
            error_notified = true if event.type == :error
          end
        })
        agent.stream(input.to_s)
      rescue => error
        unless error_notified
          begin
            delivery.publish(type: "error", message: error.message)
          rescue => notification_error
            Rails.logger.warn("[AgentStreamingJob] Error notification failed: #{notification_error.message}")
          end
        end
        raise
      end
    end
  end

  private

  def event_payload(event)
    case event.type
    when :token
      {type: "token", content: event.payload[:content].to_s}
    when :tool_call
      {type: "tool_call", tool: event.payload[:tool_call]&.name.to_s}
    when :tool_result
      {type: "tool_result"}
    when :done
      {type: "done", output: event.payload[:output].to_s}
    when :error
      {type: "error", message: event.payload[:error]&.message.to_s}
    end
  end
end
