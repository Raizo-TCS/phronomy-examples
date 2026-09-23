# frozen_string_literal: true

# Phronomy configuration initializer for 15_rails_secure_chat.
# Demonstrates NIST AI RMF trustworthy-AI enhancements.

require_relative "../../../shared/llm_config"

LLM_MODEL = LLMConfig::MODEL

Phronomy.configure do |config|
  config.default_model = LLM_MODEL
end

# Feature D: TTL in seconds.
# 30 seconds for easy demo verification; use 30.days.to_i in production.
PHRONOMY_MEMORY_TTL = 30

# Shared InMemory persistence for all SecureChatAgent instances.
# In production, replace with a durable Persistence backend.
module PhronomyStore
  class << self
    attr_reader :persistence
  end

  @persistence = Phronomy::Persistence.in_memory
end
