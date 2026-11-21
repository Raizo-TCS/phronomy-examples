# frozen_string_literal: true

require "phronomy"

# Example-owned allocation. The Adapter reads registered capacity without inference.
module Example05Budget
  Allocation = Data.define(:context_window, :output_tokens, :safety_margin, :input_tokens)

  def self.allocate(window:, output_limit: nil)
    unless window.is_a?(Integer) && window.positive?
      raise Phronomy::ConfigurationError,
        "Example 05 requires known model context capacity; configure PHRONOMY_CONTEXT_WINDOW"
    end
    if !output_limit.nil? && !(output_limit.is_a?(Integer) && output_limit.positive?)
      raise Phronomy::ConfigurationError, "Example 05 requires a positive output capacity when supplied"
    end

    output = window / 4
    output = [output, output_limit].min if output_limit
    margin = [window / 16, 1].max
    input = window - output - margin
    unless output.positive? && input.positive?
      raise Phronomy::ConfigurationError, "Model capacity is too small for Example 05 allocation"
    end

    Allocation.new(context_window: window, output_tokens: output,
      safety_margin: margin, input_tokens: input)
  end

  def self.current
    config = {"model" => LLMConfig::MODEL, "provider" => LLMConfig::PROVIDER&.to_s}.compact
    budget = Phronomy.configuration.llm_adapter.input_budget(config)
    # Independent output capacity belongs to the SDK registry, not ContextPolicy.
    model = begin
      RubyLLM.models.find(LLMConfig::MODEL, provider: LLMConfig::PROVIDER)
    rescue RubyLLM::ModelNotFoundError
      nil
    end
    allocate(window: budget&.max_input_tokens, output_limit: model&.max_output_tokens)
  end

  def self.patch(_context)
    Phronomy::Context::LLMInputPatch.new(
      model_config_patch: {max_output_tokens: current.output_tokens}
    )
  end
end

class Example05InputPolicy < Phronomy::Context::ContextPolicy
  def call(input)
    output = input.model_config["max_output_tokens"]
    unless output.is_a?(Integer) && output.positive?
      raise Phronomy::ConfigurationError, "Example 05 requires its allocated output cap on every call"
    end
    allocation = Example05Budget.allocate(window: input.input_token_limit, output_limit: output)
    unless allocation.output_tokens == output
      raise Phronomy::ConfigurationError, "Output cap exceeds Example 05's share of the current context"
    end

    # DefaultPolicy estimates Tools individually; account for the full array too.
    tool_overhead = [estimate_tokens(input.tools.map(&:definition)) - input.tools.sum(&:estimated_tokens), 0].max
    selection_limit = allocation.input_tokens - tool_overhead
    if selection_limit <= 0
      raise Phronomy::Context::BudgetExceededError, "No Example 05 input budget remains after Tool framing"
    end
    selected = Phronomy::Context::DefaultPolicy.instance.call(
      input.with_input_token_limit(selection_limit)
    )
    items = selected.instruction + selected.knowledge + selected.conversation.flatten
    cost = items.sum { |item| estimate_tokens(item.content) } + estimate_tokens(selected.tools.map(&:definition))
    if cost > allocation.input_tokens
      raise Phronomy::Context::BudgetExceededError, "Selected Example 05 input exceeds its allocation"
    end

    plan(instruction: selected.instruction, knowledge: selected.knowledge,
      tools: selected.tools, conversation: selected.conversation,
      metadata: selected.metadata.merge(
        "example05_context_window" => allocation.context_window,
        "example05_output_tokens" => output,
        "example05_safety_margin" => allocation.safety_margin,
        "example05_input_limit" => allocation.input_tokens,
        "example05_selected_tokens" => cost
      ))
  end
end
