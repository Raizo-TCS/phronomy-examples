# frozen_string_literal: true

ENV["PHRONOMY_MODEL"] = "gpt-4o-mini"
ENV["PHRONOMY_PROVIDER"] = "openai"
ENV["PHRONOMY_BASE_URL"] = "https://example.test/v1"
ENV["PHRONOMY_API_KEY"] = "test-only"
ENV["PHRONOMY_CONTEXT_WINDOW"] = "8192"
# Offline examples use an explicit baseline; compatibility cases opt in locally.
# The live integration suite does not load this helper and inherits the caller.
ENV["PHRONOMY_TRUST_LLM_MODE"] = "native"
ENV["PHRONOMY_TRACING_LLM_MODE"] = "native"

require "phronomy"
require "webmock/rspec"
require_relative "../shared/llm_config"
require_relative "support/chat_stub"

RSpec.configure do |config|
  config.before do
    WebMock.disable_net_connect!
  end

  config.after do
    Phronomy.reset_runtime!
  end
end
