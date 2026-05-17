# frozen_string_literal: true

# Stores conversation messages keyed by thread_id.
# v0.3.0: Phronomy::Memory module removed. Messages are persisted manually
# and passed to agents via config[:messages].
class PhronomyMessage < ApplicationRecord
  # Load all messages for a thread as RubyLLM::Message objects.
  def self.load_messages(thread_id)
    where(thread_id: thread_id).order(:created_at).filter_map do |record|
      tool_calls = deserialize_tool_calls(record.tool_calls_json)
      RubyLLM::Message.new(
        role:       record.role,
        content:    record.content,
        model_id:   record.model_id,
        tool_calls: tool_calls
      )
    rescue => e
      Rails.logger.warn("PhronomyMessage.load_messages: skipping record #{record.id}: #{e.message}")
      nil
    end
  end

  # Replace all stored messages for a thread with the given array.
  def self.save_messages(thread_id, messages)
    transaction do
      where(thread_id: thread_id).delete_all
      messages.each do |msg|
        content_str = msg.content.is_a?(String) ? msg.content : msg.content.to_s
        create!(
          thread_id:       thread_id,
          role:            msg.role.to_s,
          content:         content_str,
          tool_calls_json: serialize_tool_calls(msg),
          model_id:        msg.respond_to?(:model_id) ? msg.model_id : nil
        )
      end
    end
  end

  class << self
    private

    def serialize_tool_calls(msg)
      return unless msg.respond_to?(:tool_calls) && msg.tool_calls

      serializable = case msg.tool_calls
      when Hash  then msg.tool_calls.transform_values { |tc| tc.respond_to?(:to_h) ? tc.to_h : tc }
      when Array then msg.tool_calls.map { |tc| tc.respond_to?(:to_h) ? tc.to_h : tc }
      else msg.tool_calls
      end
      JSON.generate(serializable)
    end

    def deserialize_tool_calls(json)
      return nil unless json

      parsed = JSON.parse(json)
      case parsed
      when Hash  then parsed.transform_values { |tc| restore_tool_call(tc) }
      when Array then parsed.map { |tc| restore_tool_call(tc) }
      else parsed
      end
    end

    def restore_tool_call(tc)
      return tc unless tc.is_a?(Hash) && tc["id"] && tc["name"]
      RubyLLM::ToolCall.new(id: tc["id"], name: tc["name"], arguments: tc["arguments"] || {})
    end
  end
end
