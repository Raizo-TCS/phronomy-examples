# frozen_string_literal: true

# Phronomy configuration initializer.
# Customize LLM settings and agent defaults here.
Phronomy.configure do |config|
  # Default LLM model used when no model is specified on an agent or chain.
  config.default_model = "openai/gpt-oss-20b"

  # Maximum graph recursion depth (node steps per invoke).
  # config.recursion_limit = 25
end

# RubyLLM provider credentials.
# Edit the constants below to switch LLM providers.
LLM_MODEL    = "openai/gpt-oss-20b"
LLM_BASE_URL = "http://192.168.122.1:1234/v1"
LLM_API_KEY  = "lm-studio"

RubyLLM.configure do |c|
  c.openai_api_key  = LLM_API_KEY
  c.openai_api_base = LLM_BASE_URL
end
