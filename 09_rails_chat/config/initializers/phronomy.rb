# frozen_string_literal: true

require_relative "../../../shared/llm_config"

LLM_MODEL = LLMConfig::MODEL

Phronomy.configure do |config|
  config.default_model = LLM_MODEL
end
