# frozen_string_literal: true

require "phronomy"
require_relative "../shared/llm_config"

# ---------------------------------------------------------------------------
# Static knowledge cached once per agent instance via ContextVersionCache.
# Each reviewer's criteria text is fingerprinted; the system prompt is not
# rebuilt on subsequent calls as long as the text remains unchanged.
# ---------------------------------------------------------------------------

SECURITY_CRITERIA = Phronomy::Agent::Context::Knowledge::Source::StaticKnowledge.new(
  "Key security risks to detect in Ruby: SQL injection via string interpolation, " \
  "command injection (system/exec/backtick), exposed credentials or API keys, " \
  "insecure deserialization (YAML.load/Marshal.load), mass assignment, path traversal, " \
  "missing authentication or authorisation checks.",
  type: :policy
)

PERFORMANCE_CRITERIA = Phronomy::Agent::Context::Knowledge::Source::StaticKnowledge.new(
  "Key performance risks to detect in Ruby: N+1 database queries, " \
  "unnecessary object allocations inside loops, repeated costly computations, " \
  "missing memoization, synchronous I/O that could be async, missing DB indexes.",
  type: :policy
)

READABILITY_CRITERIA = Phronomy::Agent::Context::Knowledge::Source::StaticKnowledge.new(
  "Key readability issues to detect in Ruby: overly long methods (> 20 lines), " \
  "missing or outdated documentation, poor variable/method naming, " \
  "deeply nested conditions (> 2 levels), magic numbers or string literals, " \
  "methods doing too many things (SRP violations).",
  type: :policy
)

ABSTRACTION_CRITERIA = Phronomy::Agent::Context::Knowledge::Source::StaticKnowledge.new(
  "Abstraction-level consistency rules for Ruby code: " \
  "(1) Methods in the same class/module should operate at the same level — mixing high-level " \
  "business operations (e.g. process_order) with low-level implementation helpers " \
  "(e.g. pad_string_to_length) in the same public interface is inconsistent. " \
  "(2) Statements within the same method should stay at one abstraction level — " \
  "mixing domain-level calls (e.g. create_invoice(order)) with micro-manipulation " \
  "(e.g. order.items.select{|i| i.qty>0}.map(&:sku).join(',')) breaks coherence. " \
  "(3) Fields of the same data structure or initializer should represent concepts " \
  "at similar granularity — e.g. pairing :name and :raw_sql_fragment is inconsistent. " \
  "(4) Parameters of the same method should be at similar abstraction levels — " \
  "mixing a domain object with a raw byte offset in the same signature is inconsistent.",
  type: :policy
)

# Output token ceiling for all reviewer agents.
# The output format is one line per finding: "[SEVERITY] line NNN — description".
# Capped at 512 tokens absolute (enough for ~15 findings even in Japanese where
# each line costs ~30–40 tokens), but reduced to 15% of the context window on
# smaller deployments so output does not crowd out the source input.
REVIEWER_MAX_OUTPUT_TOKENS = [512, (LLMConfig::EFFECTIVE_CONTEXT_WINDOW * 0.15).to_i].min

# Reviews Ruby source code for security vulnerabilities.
# Returns findings in [SEVERITY] line NNN — description format.
#
# Context management:
#   static_knowledge  — security criteria cached via ContextVersionCache.
#   max_output_tokens — bounded to REVIEWER_MAX_OUTPUT_TOKENS; one line per finding
#                       is well within this limit even for files with many issues.
#   on_trim           — drops the oldest message if unexpected history builds up.
class SecurityReviewerAgent < Phronomy::Agent::Base
  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  context_window LLMConfig::CONTEXT_WINDOW
  instructions <<~INST
    You are a security code review expert specialising in Ruby.
    When given Ruby source code, identify security vulnerabilities.
    For each issue output exactly one line:
      [SEVERITY] line NNN — description
    Severity: HIGH / MEDIUM / LOW.
    If none found: output "No security issues found." Be concise — findings only.
  INST
  static_knowledge SECURITY_CRITERIA
  max_output_tokens REVIEWER_MAX_OUTPUT_TOKENS
  max_iterations 1
  on_trim { |ctx| ctx.remove(ctx.message_elements.first[:seq]) if ctx.message_elements.size > 2 }
end

# Reviews Ruby source code for performance problems.
# Returns findings in [SEVERITY] line NNN — description format.
#
# Context management: same pattern as SecurityReviewerAgent.
class PerformanceReviewerAgent < Phronomy::Agent::Base
  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  context_window LLMConfig::CONTEXT_WINDOW
  instructions <<~INST
    You are a performance code review expert specialising in Ruby.
    When given Ruby source code, identify performance problems.
    For each issue output exactly one line:
      [SEVERITY] line NNN — description
    Severity: HIGH / MEDIUM / LOW.
    If none found: output "No performance issues found." Be concise — findings only.
  INST
  static_knowledge PERFORMANCE_CRITERIA
  max_output_tokens REVIEWER_MAX_OUTPUT_TOKENS
  max_iterations 1
  on_trim { |ctx| ctx.remove(ctx.message_elements.first[:seq]) if ctx.message_elements.size > 2 }
end

# Reviews Ruby source code for readability and maintainability issues.
# Returns findings in [SEVERITY] line NNN — description format.
#
# Context management: same pattern as SecurityReviewerAgent.
class ReadabilityReviewerAgent < Phronomy::Agent::Base
  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  context_window LLMConfig::CONTEXT_WINDOW
  instructions <<~INST
    You are a code quality and readability expert specialising in Ruby.
    When given Ruby source code, identify readability problems.
    For each issue output exactly one line:
      [SEVERITY] line NNN — description
    Severity: HIGH / MEDIUM / LOW.
    If none found: output "No readability issues found." Be concise — findings only.
  INST
  static_knowledge READABILITY_CRITERIA
  max_output_tokens REVIEWER_MAX_OUTPUT_TOKENS
  max_iterations 1
  on_trim { |ctx| ctx.remove(ctx.message_elements.first[:seq]) if ctx.message_elements.size > 2 }
end

# Reviews Ruby source code for abstraction-level consistency.
# Checks whether elements at the same structural level share a consistent
# abstraction level: method groups, intra-method statements, data structure
# fields, and method parameter lists.
#
# Context management: same pattern as SecurityReviewerAgent.
class AbstractionConsistencyReviewerAgent < Phronomy::Agent::Base
  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  context_window LLMConfig::CONTEXT_WINDOW
  instructions <<~INST
    You are a software design expert specialising in abstraction-level consistency in Ruby.
    Examine whether elements that appear at the same structural level share a
    consistent abstraction level. Check these four contexts:

    1. Methods in the same class/module — do they operate at a consistent level?
       (mixing domain-facing operations with low-level implementation helpers in
       the same public interface is an inconsistency)
    2. Statements/calls within the same method — does the method stay at one level?
       (mixing domain-level calls with micro-manipulation of data structures breaks coherence)
    3. Fields of the same data structure or initializer — do they represent concepts
       at similar granularity?
    4. Parameters of the same method — are they at similar abstraction levels?

    For each inconsistency output exactly one line:
      [SEVERITY] line NNN — description
    Severity: HIGH / MEDIUM / LOW.
    If none found: output "No abstraction-level issues found." Be concise — findings only.
  INST
  static_knowledge ABSTRACTION_CRITERIA
  max_output_tokens REVIEWER_MAX_OUTPUT_TOKENS
  max_iterations 1
  on_trim { |ctx| ctx.remove(ctx.message_elements.first[:seq]) if ctx.message_elements.size > 2 }
end
