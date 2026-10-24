# frozen_string_literal: true

module PhronomyExamples
  # Text presentation for these chat applications. Agent owns durable Message
  # restoration; the application chooses visible roles and text content.
  module TranscriptMessages
    def self.read(agent)
      agent.transcript_messages.filter_map do |message|
        next unless %i[user assistant].include?(message.role)
        content = message.content
        next unless content.is_a?(String) && !content.empty?

        {"role" => message.role.to_s, "content" => content}
      end
    end
  end
end
