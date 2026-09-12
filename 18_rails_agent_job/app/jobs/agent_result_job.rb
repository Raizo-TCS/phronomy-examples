# frozen_string_literal: true

# Basic ActiveJob integration: run the Agent synchronously on the Job thread and
# broadcast the final result. No listener or local delivery queue is involved.
class AgentResultJob < ApplicationJob
  queue_as :default

  AGENTS = {"DemoAgent" => DemoAgent}.freeze

  def perform(agent_class_name, input, stream:)
    agent_class = AGENTS.fetch(agent_class_name) do
      raise ArgumentError, "unsupported agent_class_name: #{agent_class_name}"
    end

    agent = agent_class.new
    result = agent.invoke(input.to_s)
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