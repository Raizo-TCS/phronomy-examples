# frozen_string_literal: true

# Configure Phronomy (and RubyLLM) for this Rails application.
# All LLM settings are centralised in shared/llm_config.rb.
require_relative "../../../shared/llm_config"

Rails.application.config.after_initialize do
  RubyLLM.configure do |c|
    c.openai_api_key = LLMConfig::API_KEY   if LLMConfig::API_KEY
    c.openai_api_base = LLMConfig::BASE_URL if LLMConfig::BASE_URL
  end
end
