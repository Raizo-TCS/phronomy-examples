# frozen_string_literal: true

# Application acceptance checks over public Agent result values.
module Example05Validation
  class InvalidOutput < StandardError; end

  def self.require_text!(value, message)
    raise InvalidOutput, message unless value.is_a?(String) && !value.strip.empty?
  end

  def self.article!(result)
    article = nil
    calls = {}
    research_results = []
    valid_writes = {}
    result.fetch(:messages).each do |message|
      if message.role == :assistant
        message.tool_calls.each do |call|
          calls[call.id] = call
          next unless call.name == "write"

          notes = call.arguments["research_notes"]
          valid_writes[call.id] = notes.is_a?(String) && !notes.strip.empty? &&
            research_results.include?(notes)
        end
      elsif message.role == :tool
        call = calls[message.tool_call_id]
        next unless call

        if call.name == "research"
          require_text!(message.content, "The research Tool returned no notes")
          research_results << message.content
        elsif call.name == "write"
          unless valid_writes[call.id]
            raise InvalidOutput, "The write call did not receive a complete earlier research result"
          end
          require_text!(message.content, "The write Tool returned no article")
          article = message.content
        end
      end
    end
    unless article
      raise InvalidOutput, "No completed research-to-write handoff produced an article"
    end
    raise InvalidOutput, "The article must contain at least 300 characters" if article.strip.length < 300
    article
  end
end
