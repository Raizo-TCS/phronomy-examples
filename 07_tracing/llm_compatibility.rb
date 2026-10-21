# frozen_string_literal: true

require "ruby_llm"

# An explicit application choice for this example, not a server capability probe.
module TracingLLMCompatibility
  MODE = "lmstudio_gpt_oss"
  MODEL = "openai/gpt-oss-20b"
  PROTOCOL = :example07_lmstudio_gpt_oss

  # RubyLLM's public protocol extension seam retains its normal serialization,
  # transport, parsing and usage handling. The built-in protocol is unchanged.
  class ChatCompletions < RubyLLM::Protocols::ChatCompletions
    def render_payload(messages, model:, **options)
      raise ArgumentError, "Example 07 compatibility requires #{MODEL}" unless model.id == MODEL

      super.merge(repeat_penalty: 1.0)
    end
  end

  def self.configure!(mode:, model:, provider:, base_url:)
    return false if mode == "native"
    raise ArgumentError, "Unknown PHRONOMY_TRACING_LLM_MODE: #{mode.inspect}" unless mode == MODE
    unless model == MODEL && provider == :openai && !base_url.to_s.empty?
      raise ArgumentError, "#{MODE} requires #{MODEL}, provider openai and an explicit PHRONOMY_BASE_URL"
    end
    unless RubyLLM.config.openai_protocol == :chat_completions
      raise ArgumentError, "#{MODE} requires the Chat Completions protocol"
    end

    RubyLLM::Providers::OpenAI.protocol(PROTOCOL, ChatCompletions)
    RubyLLM.configure do |config|
      config.openai_protocol = PROTOCOL
      # This opt-in evaluation performs one attempt, including transport errors.
      config.max_retries = 0
    end
    true
  end
end
