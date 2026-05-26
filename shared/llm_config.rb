# frozen_string_literal: true

require "ruby_llm"
require "net/http"
require "json"
require "uri"

# Central LLM configuration for all examples.
#
# All values are read from environment variables so that external users
# do not need to edit source files.  Typical setup:
#
#   export PHRONOMY_MODEL="gpt-4o-mini"        # required for OpenAI
#   export OPENAI_API_KEY="sk-..."             # required for OpenAI
#
# For a local LM Studio instance:
#   export PHRONOMY_MODEL="openai/gpt-oss-20b"
#   export PHRONOMY_BASE_URL="http://192.168.122.1:1234/v1"
#   export PHRONOMY_API_KEY="lm-studio"
#
# See README.md for a full list of supported environment variables.
module LLMConfig
  # Model identifier passed to RubyLLM / phronomy.
  MODEL = ENV.fetch("PHRONOMY_MODEL", "gpt-4o-mini")

  # Provider symbol passed to RubyLLM.  When set together with a custom
  # BASE_URL (e.g. LM Studio, Ollama, vLLM), phronomy sets
  # assume_model_exists so RubyLLM does not reject unknown model names.
  # Set PHRONOMY_PROVIDER="" (or leave unset) to let RubyLLM infer the
  # provider from the model identifier.
  PROVIDER = ENV["PHRONOMY_PROVIDER"].then { |v| v && !v.empty? ? v.to_sym : nil }

  # Provider base URL. Leave unset to use the RubyLLM default (openai.com).
  BASE_URL = ENV["PHRONOMY_BASE_URL"].then { |v| v && !v.empty? ? v : nil }

  # API key.  Falls back to OPENAI_API_KEY for standard OpenAI usage.
  API_KEY = ENV["PHRONOMY_API_KEY"] || ENV["OPENAI_API_KEY"]

  # LM Studio management API base URL (derived from BASE_URL when set).
  # Used to query the actually-loaded context window size at runtime.
  # Falls back to nil for non-LM-Studio providers.
  LM_STUDIO_API_BASE = BASE_URL ? BASE_URL.sub(%r{/v1.*$}, "") : nil

  # Queries the LM Studio management API for the context window size that
  # the model is currently loaded with.  This value can differ from the
  # model's theoretical maximum because LM Studio lets users configure a
  # smaller loaded_context_length (e.g. 4096 even when max is 131072).
  #
  # Returns nil when the API is unreachable or BASE_URL is not set.
  def self.fetch_loaded_context_window
    return nil unless LM_STUDIO_API_BASE

    uri = URI.parse("#{LM_STUDIO_API_BASE}/api/v0/models/#{MODEL}")
    response = Net::HTTP.get_response(uri)
    return nil unless response.is_a?(Net::HTTPSuccess)

    data = JSON.parse(response.body)
    data["loaded_context_length"]&.to_i
  rescue StandardError
    nil
  end

  # The context window size actually loaded in the server right now.
  # Can be overridden via PHRONOMY_CONTEXT_WINDOW.
  # Falls back to 8192 when the management API is unavailable.
  CONTEXT_WINDOW = ENV["PHRONOMY_CONTEXT_WINDOW"]&.to_i ||
                   fetch_loaded_context_window ||
                   8192

  # Fraction of CONTEXT_WINDOW used for per-request token budgets.
  # Set to 1.0 to use the full declared context window.
  CONTEXT_WINDOW_UTILIZATION = 1.0
  EFFECTIVE_CONTEXT_WINDOW = (CONTEXT_WINDOW * CONTEXT_WINDOW_UTILIZATION).to_i

  # Configure RubyLLM once when this file is loaded.
  RubyLLM.configure do |config|
    config.openai_api_key = API_KEY if API_KEY
    config.openai_api_base = BASE_URL if BASE_URL
    # Local servers (LM Studio, Ollama, etc.) do not define a 'developer' role
    # in their chat templates; force 'system' role when using a custom base URL.
    config.openai_use_system_role = true if BASE_URL
  end
end
