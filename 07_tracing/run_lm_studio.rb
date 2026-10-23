#!/usr/bin/env ruby
# frozen_string_literal: true

# Explicit application composition for the current gpt-oss development setup.
require_relative "../shared/llm_config"

unless LLMConfig::BASE_URL && LLMConfig::PROVIDER == :openai && LLMConfig::MODEL == "openai/gpt-oss-20b"
  raise ArgumentError, "Set an LM Studio base URL, provider openai, and model openai/gpt-oss-20b"
end

Phronomy.configure do |config|
  config.llm_adapter = Phronomy::LLMAdapter::LMStudio.new(
    context: RubyLLM.context,
    max_parse_retries: 1
  )
end

require_relative "run"
