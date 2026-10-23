# frozen_string_literal: true

require_relative "../shared/llm_config"

# Application-owned transport policy for approval_demo.rb, selected at startup.
# GeneratorVerifier still owns the same Agents, schemas, approval and Result.
module TrustLlmCompatibility
  ENV_KEY = "PHRONOMY_TRUST_LLM_MODE"
  TOOL_NAME = "approved_policy_lookup"

  def self.mode
    value = ENV.fetch(ENV_KEY, "native")
    unless %w[native tool_then_schema].include?(value)
      raise ArgumentError, "#{ENV_KEY} must be native or tool_then_schema"
    end
    value
  end

  def self.configure!
    return if mode == "native"

    unless LLMConfig::PROVIDER == :openai && RubyLLM.config.openai_protocol == :chat_completions
      raise ArgumentError, "tool_then_schema requires the configured OpenAI-compatible Chat Completions path"
    end
    backend = Phronomy.configuration.llm_adapter
    unless backend.instance_of?(Phronomy::LLMAdapter::RubyLLM)
      raise ArgumentError, "Configure this example once at startup with the default RubyLLM backend"
    end
    Phronomy.configure do |config|
      config.llm_adapter = ApprovedLookupAdapter.new(backend: backend, model: LLMConfig::MODEL)
    end
  end

  # One approved lookup per draft. This is deliberately not a general Tool loop
  # emulator: each Agent call still makes exactly one backend operation.
  class ApprovedLookupAdapter < Phronomy::LLMAdapter::Base
    def initialize(backend:, model:)
      @backend, @model = backend, model
    end

    def identity
      @backend.identity.merge(super).merge("policy" => "example19.approved_lookup_then_schema.v1",
        "model" => @model, "provider" => "openai", "backend" => @backend.identity).freeze
    end

    def input_budget(model_config)
      @backend.input_budget(model_config)
    end

    protected

    def perform_complete(request, cancellation_token:)
      return @backend.complete(request, cancellation_token: cancellation_token) unless adapt?(request)

      phase = phase_for(request)
      wire_request = Phronomy::LLMAdapter::Request.new(
        model_config: request.model_config, system: request.system,
        messages: request.messages, message: request.message,
        tools: phase == "tool" ? request.tools : [],
        response_schema: phase == "schema" ? request.response_schema : nil
      )
      response = @backend.complete(wire_request, cancellation_token: cancellation_token)
      validate_phase_response!(phase, response)
      Phronomy::LLMAdapter::Response.from_h(response.to_h.merge(
        "metadata" => response.metadata.merge("example19_transport_phase" => phase)
      ))
    end

    def perform_stream(request, cancellation_token:, &block)
      if adapt?(request)
        raise Phronomy::LLMAdapter::StructuredOutputUnsupportedError,
          "Example 19 tool_then_schema supports non-streaming approval invocations only"
      end
      @backend.stream(request, cancellation_token: cancellation_token, &block)
    end

    private

    def adapt?(request)
      request.model_config["model"] == @model && request.model_config["provider"] == "openai" &&
        request.response_schema && !request.tools.empty?
    end

    def phase_for(request)
      unless request.tools.map { |tool| tool.fetch("name") } == [TOOL_NAME]
        raise Phronomy::LLMAdapter::InvalidResultError, "Example 19 policy supports only approved_policy_lookup"
      end
      # A new question starts a new lookup, even when reused Agent history
      # contains a previous lookup. No mutable phase counter is kept here.
      return "tool" if request.message || request.messages.last&.role != :tool

      result = request.messages.last
      assistant = request.messages[-2]
      call = assistant&.tool_calls&.first
      unless assistant&.role == :assistant && assistant.tool_calls.length == 1 &&
          call.name == TOOL_NAME && call.id == result.tool_call_id
        raise Phronomy::LLMAdapter::InvalidResultError, "Example 19 requires one correlated lookup result"
      end
      "schema"
    end

    def validate_phase_response!(phase, response)
      if phase == "schema"
        unless response.tool_calls.empty?
          raise Phronomy::LLMAdapter::InvalidResultError, "Tool calls are unavailable during the final schema phase"
        end
        return
      end

      if response.tool_calls.empty?
        # Preserve refusal/incomplete facts for Agent's existing OutputError
        # handling. A normal answer without the required lookup is not success.
        return if response.refusal || response.finish_reason != :stop
        raise Phronomy::LLMAdapter::InvalidResultError, "Required approved_policy_lookup was not requested"
      end
      unless response.tool_calls.length == 1 && response.tool_calls.first.name == TOOL_NAME &&
          response.finish_reason == :tool_calls && response.refusal.nil?
        raise Phronomy::LLMAdapter::InvalidResultError, "Expected one normally completed approved_policy_lookup request"
      end
    end
  end
end
