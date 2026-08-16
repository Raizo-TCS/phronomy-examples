# frozen_string_literal: true

# Phronomy configuration initializer.
# The repository verification script supplies these environment variables when
# exercising examples against a local OpenAI-compatible endpoint.
LLM_MODEL = ENV.fetch("PHRONOMY_MODEL", "openai/gpt-oss-20b")
LLM_BASE_URL = ENV.fetch("PHRONOMY_BASE_URL", "http://192.168.122.1:1234/v1")
LLM_API_KEY = ENV.fetch("PHRONOMY_API_KEY", "lm-studio")

Phronomy.configure do |config|
  # Default LLM model used when no model is specified on an agent or chain.
  config.default_model = LLM_MODEL

  # Reserve 25% of the context window for output when the model registry does
  # not publish max_output_tokens (e.g. locally-hosted models).
  context_window = 131_072
  config.default_output_reserve = (context_window * 0.25).to_i.clamp(256, 4096)
end

RubyLLM.configure do |config|
  config.openai_api_key = LLM_API_KEY
  config.openai_api_base = LLM_BASE_URL
end
