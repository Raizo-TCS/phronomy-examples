# frozen_string_literal: true

# The Job owns the Agent through final delivery; scope then releases its owner.
class AgentResultJob < ApplicationJob
  queue_as :default

  AGENTS = {"DemoAgent" => DemoAgent}.freeze

  def perform(agent_class_name, input, stream:)
    Phronomy::Agent.open_scope do |agents|
      begin
        agent_class = AGENTS.fetch(agent_class_name) do
          raise ArgumentError, "unsupported agent_class_name: #{agent_class_name}"
        end
        result = agents.create(agent_class).invoke(input.to_s)
        ActionCable.server.broadcast(stream, {type: "done", output: result[:output].to_s})
      rescue => error
        begin
          ActionCable.server.broadcast(stream, {type: "error", message: error.message})
        rescue => notification_error
          Rails.logger.warn("[AgentResultJob] Error notification failed: #{notification_error.message}")
        end
        raise error
      end
    end
  end
end
