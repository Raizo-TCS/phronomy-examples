# frozen_string_literal: true

module PhronomyExamples
  # Text presentation for these chat applications. External messages are text;
  # assistant_message records contain a saved Provider response. User text must
  # never be guessed to be a Provider envelope just because it parses as JSON.
  module TranscriptMessages
    def self.read(agent)
      agent.transcript.filter_map do |record|
        next unless %i[user assistant].include?(record.role) && record.content_ref

        content = if record.kind == :assistant_message
          agent.persistence.contents.fetch_json(record.content_ref).fetch("content")
        else
          agent.persistence.contents.fetch_text(record.content_ref)
        end
        next unless content.is_a?(String) && !content.empty?

        {"role" => record.role.to_s, "content" => content}
      end
    end
  end
end
