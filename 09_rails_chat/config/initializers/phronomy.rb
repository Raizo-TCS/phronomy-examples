# frozen_string_literal: true

# Phronomy configuration initializer.
# The repository verification script supplies these environment variables when
# exercising examples against a local OpenAI-compatible endpoint.
LLM_MODEL = ENV.fetch("PHRONOMY_MODEL", "openai/gpt-oss-20b")
LLM_BASE_URL = ENV.fetch("PHRONOMY_BASE_URL", "http://192.168.122.1:1234/v1")
LLM_API_KEY = ENV.fetch("PHRONOMY_API_KEY", "lm-studio")
LLM_OUTPUT_RESERVE = Integer(ENV.fetch("PHRONOMY_OUTPUT_RESERVE", "4096"), 10)

Phronomy.configure do |config|
  # Default LLM model used when no model is specified on an agent or chain.
  config.default_model = LLM_MODEL

  # Some locally-hosted models do not publish max_output_tokens through the
  # model registry. Use an explicit fallback reserve and keep it below the
  # selected model's context window.
  config.default_output_reserve = LLM_OUTPUT_RESERVE
end

RubyLLM.configure do |config|
  config.openai_api_key = LLM_API_KEY
  config.openai_api_base = LLM_BASE_URL
end
