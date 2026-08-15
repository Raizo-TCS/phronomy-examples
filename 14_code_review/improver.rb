# frozen_string_literal: true

require "phronomy"
require_relative "../shared/llm_config"

IMPROVER_MAX_OUTPUT_TOKENS = [1024, (LLMConfig::EFFECTIVE_CONTEXT_WINDOW * 0.25).to_i].min
IMPROVE_OVERHEAD_TOKENS = 150 + 150 + 200 + IMPROVER_MAX_OUTPUT_TOKENS

# Persistent Knowledge is application content written to the Agent Journal.
# The pipeline supplies this string via knowledge: when the Agent is created.
IMPROVEMENT_POLICY = (
  "Return ONLY the improved Ruby code inside a ```ruby ... ``` fenced block. " \
  "No explanations, preamble, or commentary outside the code block."
).freeze

IMPROVE_TEMPLATE = Phronomy::Agent::Context::Instruction::PromptTemplate.new(
  template: <<~TMPL,
    Focus area: {{priority}}

    Source code excerpt ({{char_count}} chars shown):
    ```ruby
    {{source_excerpt}}
    ```

    Review findings for {{priority}}:
    {{review_text}}

    Provide the improved Ruby code that addresses the {{priority}} issues above.
    Return ONLY the improved code inside a ```ruby ... ``` block.
  TMPL
  system_template: "You are an expert Ruby developer. Fix the {{priority}} issues and return the improved code in a ```ruby ... ``` block."
)

class ImproverAgent < Phronomy::Agent::Base
  agent_definition id: "example-14-improver-agent", version: 2

  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  context_window LLMConfig::CONTEXT_WINDOW
  instructions { |input| "Fix the #{input[:priority]} issues and return the improved code in a ```ruby ... ``` block." }
  max_output_tokens IMPROVER_MAX_OUTPUT_TOKENS
  max_iterations 1
end
