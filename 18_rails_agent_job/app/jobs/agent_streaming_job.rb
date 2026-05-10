# frozen_string_literal: true

# Thin wrapper around Phronomy::Rails::AgentJob.
# Exists so we can set a custom queue name without subclassing the library job.
class AgentStreamingJob < ApplicationJob
  queue_as :default

  # Delegates entirely to the phronomy job.
  # @param agent_class_name [String]
  # @param input            [String]
  # @param stream           [String] ActionCable stream identifier
  def perform(agent_class_name, input, stream:)
    Phronomy::Rails::AgentJob.new.perform(
      agent_class_name,
      input,
      channel: "AgentChannel",
      stream: stream
    )
  end
end
