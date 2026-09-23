# frozen_string_literal: true

require "ruby_llm"
require "net/http"
require "json"
require "uri"
require "tempfile"

# Application configuration. Model capabilities belong to RubyLLM's registry;
# Agent.max_output_tokens is a separate per-request output cap.
module LLMConfig
  MODEL = ENV.fetch("PHRONOMY_MODEL", "gpt-4o-mini")
  BASE_URL = ENV["PHRONOMY_BASE_URL"].then { |value| value unless value.to_s.empty? }
  PROVIDER = ENV["PHRONOMY_PROVIDER"].then do |value|
    value.to_s.empty? ? (BASE_URL ? :openai : nil) : value.to_sym
  end
  API_KEY = ENV["PHRONOMY_API_KEY"] || ENV["OPENAI_API_KEY"]

  RubyLLM.configure do |config|
    config.openai_api_key = API_KEY if API_KEY
    config.openai_api_base = BASE_URL if BASE_URL
    if BASE_URL
      config.openai_protocol = :chat_completions
      config.openai_use_system_role = true
    end
  end

  # Optional LM Studio metadata. Failure means unknown, never a guessed limit.
  def self.fetch_loaded_context_window
    return unless BASE_URL && PROVIDER == :openai

    uri = URI.parse("#{BASE_URL.sub(%r{/v1.*$}, "")}/api/v0/models/#{MODEL}")
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
      open_timeout: 2, read_timeout: 2) { |http| http.get(uri.request_uri) }
    return unless response.is_a?(Net::HTTPSuccess)

    value = JSON.parse(response.body)["loaded_context_length"]
    value if value.is_a?(Integer) && value.positive?
  rescue StandardError
    nil
  end

  # Load application-provided capabilities through RubyLLM's public registry API.
  # Keep the other registry entries, including provider-qualified duplicates.
  def self.configure_model_registry!
    explicit = ENV["PHRONOMY_CONTEXT_WINDOW"]
    limit = if explicit && !explicit.empty?
      Integer(explicit, 10).tap do |value|
        raise ArgumentError, "PHRONOMY_CONTEXT_WINDOW must be positive" unless value.positive?
      end
    else
      fetch_loaded_context_window
    end
    return unless BASE_URL || limit

    existing = begin
      RubyLLM.models.find(MODEL, provider: PROVIDER)
    rescue RubyLLM::ModelNotFoundError
      nil
    end
    provider = PROVIDER&.to_s || existing&.provider
    raise ArgumentError, "Set PHRONOMY_PROVIDER for a custom model" unless provider

    model = (existing&.to_h || {
      id: MODEL, name: MODEL, provider: provider,
      modalities: {input: ["text"], output: ["text"]},
      capabilities: ["function_calling", "streaming"]
    }).merge(context_window: limit)
    models = (RubyLLM.models.all + RubyLLM.models.unlisted).map(&:to_h)
    models.reject! { |entry| entry[:id] == model[:id] && entry[:provider] == provider }
    models << model
    Tempfile.create(["phronomy-example-models", ".json"]) do |file|
      file.write(JSON.generate(models))
      file.flush
      RubyLLM.models.load_from_json(file.path)
    end
  end

  # Chunking examples require known metadata; ordinary agents may run without it.
  def self.input_token_limit!
    limit = RubyLLM.models.find(MODEL, provider: PROVIDER).context_window
    return limit if limit.is_a?(Integer) && limit.positive?

    raise ArgumentError, "This example requires model input metadata; set PHRONOMY_CONTEXT_WINDOW"
  end

  configure_model_registry!
end

require "phronomy"
