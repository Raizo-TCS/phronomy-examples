# frozen_string_literal: true

require "phronomy"
require_relative "../shared/llm_config"

# Output token ceiling for ImproverAgent.
# Capped at 1024 tokens absolute (sufficient to rewrite the source excerpt
# passed as MAX_IMPROVE_CHARS), but limited to 25% of the context window on
# smaller deployments to avoid crowding out input tokens.
IMPROVER_MAX_OUTPUT_TOKENS = [1024, (LLMConfig::EFFECTIVE_CONTEXT_WINDOW * 0.25).to_i].min

# Overhead tokens reserved for system prompt, review findings, conversation
# history, and output. The remainder of the context window is available for
# source content — calculated dynamically in IMPROVE_NODE based on actual
# source size so the largest possible excerpt is always passed.
# Budget breakdown (≈4 chars/token):
#   system prompt + static_knowledge  : ~150 tokens
#   review findings                   : ~150 tokens
#   conversation history (compacted)  : ~200 tokens
#   output (IMPROVER_MAX_OUTPUT_TOKENS): IMPROVER_MAX_OUTPUT_TOKENS tokens
IMPROVE_OVERHEAD_TOKENS = 150 + 150 + 200 + IMPROVER_MAX_OUTPUT_TOKENS

# Static output-format policy cached once per ImproverAgent instance.
# ContextVersionCache ensures this text is fingerprinted and not re-assembled
# on every call when the source text has not changed.
IMPROVEMENT_POLICY = Phronomy::Agent::Context::Knowledge::StaticKnowledge.new(
  "Return ONLY the improved Ruby code inside a ```ruby ... ``` fenced block. " \
  "No explanations, preamble, or commentary outside the code block.",
  type: :policy
)

# PromptTemplate used to build the user message sent to ImproverAgent.
# Variables: priority, source_excerpt, char_count, review_text.
# Uses source_excerpt (truncated) rather than the full source to stay within
# the model's context window (LLMConfig::CONTEXT_WINDOW tokens).
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

# Generates improved Ruby code for a chosen review perspective.
#
# Context management strategy (fits within LLMConfig::CONTEXT_WINDOW tokens):
#
#   static_knowledge    — IMPROVEMENT_POLICY cached via ContextVersionCache;
#                         system text is not rebuilt when fingerprint is stable.
#   build_context       — trims and compacts history to stay within token budget:
#                         * drops oldest message when history exceeds 4 messages
#                         * compacts messages beyond 2 into a one-line summary
class ImproverAgent < Phronomy::Agent::Base
  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  context_window LLMConfig::CONTEXT_WINDOW
  instructions { |input| "Fix the #{input[:priority]} issues and return the improved code in a ```ruby ... ``` block." }
  static_knowledge IMPROVEMENT_POLICY
  max_output_tokens IMPROVER_MAX_OUTPUT_TOKENS
  max_iterations 1

  protected

  def build_context(input, messages: [], **opts)
    msgs = Array(messages)
    # Drop the oldest message when history exceeds 2 pairs (4 messages).
    msgs = trim_messages(msgs, keep: msgs.size - 1) if msgs.size > 4
    # Compact all but the last 2 messages into a summary.
    if msgs.size > 2
      msgs = compact_messages(msgs, keep_tail: 2) do |dropped|
        lines = dropped.map { |m| "[#{m.role}] #{m.content.to_s[0, 100].tr("\n", " ")}" }
        "Prior session summary:\n#{lines.join("\n")}"
      end
    end
    super(input, messages: msgs, **opts)
  end
end
