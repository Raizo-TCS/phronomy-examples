# frozen_string_literal: true

# Phronomy configuration initializer for 15_rails_secure_chat.
# Demonstrates NIST AI RMF trustworthy-AI enhancements.

Phronomy.configure do |config|
  config.default_model = "openai/gpt-oss-20b"
end

# LLM provider settings (LM Studio compatible).
LLM_MODEL    = "openai/gpt-oss-20b"
LLM_BASE_URL = "http://192.168.122.1:1234/v1"
LLM_API_KEY  = "lm-studio"

RubyLLM.configure do |c|
  c.openai_api_key  = LLM_API_KEY
  c.openai_api_base = LLM_BASE_URL
end

# Feature C: AES-256-GCM encryptor for graph checkpoint state_json.
# Uses Rails secret_key_base so no extra secret management is needed.
PHRONOMY_ENCRYPTOR = Phronomy::StateStore::Encryptor::ActiveSupport.new(
  secret_key_base: Rails.application.secret_key_base
)

# Feature D: TTL in seconds.
# 30 seconds for easy demo verification; use 30.days.to_i in production.
PHRONOMY_MEMORY_TTL = 30

