# frozen_string_literal: true

require "ruby_llm"
require "net/http"
require "json"
require "uri"

# Central LLM configuration for all examples.
#
# To switch providers or models, edit the constants in this file only.
# Individual examples must not hardcode any of these values.
module LLMConfig
  # Model identifier passed to RubyLLM / phronomy.
  MODEL = "openai/gpt-oss-20b"

  # Provider symbol passed to RubyLLM. When set together with a custom
  # BASE_URL (e.g. LM Studio, Ollama, vLLM), phronomy will set
  # assume_model_exists so RubyLLM does not reject unknown model names.
  # Set to nil to let RubyLLM pick the provider from the model identifier.
  PROVIDER = :openai

  # Provider base URL. Set to nil to use the RubyLLM default.
  BASE_URL = "http://192.168.122.1:1234/v1"

  # API key. Set to nil to use the RubyLLM default (env var).
  API_KEY = "lm-studio"

  # LM Studio management API base URL (derived from BASE_URL).
  # Used to query the actually-loaded context window size at runtime.
  # Falls back to nil when BASE_URL is nil (non-LM-Studio providers).
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
  # Falls back to 4096 when the management API is unavailable.
  CONTEXT_WINDOW = fetch_loaded_context_window || 4096

  # Fraction of CONTEXT_WINDOW used for per-request token budgets.
  # Set to 1.0 to use the full declared context window.
  CONTEXT_WINDOW_UTILIZATION = 1.0
  EFFECTIVE_CONTEXT_WINDOW = (CONTEXT_WINDOW * CONTEXT_WINDOW_UTILIZATION).to_i

  # Configure RubyLLM once when this file is loaded.
  RubyLLM.configure do |config|
    config.openai_api_key = API_KEY
    config.openai_api_base = BASE_URL
    # LM Studio and similar local servers do not define a 'developer' role in
    # their chat templates; force 'system' role so instructions are handled
    # correctly by the endpoint.
    config.openai_use_system_role = true
  end
end
