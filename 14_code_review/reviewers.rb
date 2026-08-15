# frozen_string_literal: true

require "phronomy"
require_relative "../shared/llm_config"

# Persistent Knowledge is represented as Journal-backed context candidates.
# These constants are plain application data. The pipeline passes the selected
# policy through Agent#create/new(knowledge: [...]) rather than using the
# removed StaticKnowledge/static_knowledge API.
SECURITY_CRITERIA = (
  "Key security risks to detect in Ruby: SQL injection via string interpolation, " \
  "command injection (system/exec/backtick), exposed credentials or API keys, " \
  "insecure deserialization (YAML.load/Marshal.load), mass assignment, path traversal, " \
  "missing authentication or authorisation checks."
).freeze

PERFORMANCE_CRITERIA = (
  "Key performance risks to detect in Ruby: N+1 database queries, " \
  "unnecessary object allocations inside loops, repeated costly computations, " \
  "missing memoization, synchronous I/O that could be async, missing DB indexes."
).freeze

READABILITY_CRITERIA = (
  "Key readability issues to detect in Ruby: overly long methods (> 20 lines), " \
  "missing or outdated documentation, poor variable/method naming, " \
  "deeply nested conditions (> 2 levels), magic numbers or string literals, " \
  "methods doing too many things (SRP violations)."
).freeze

ABSTRACTION_CRITERIA = (
  "Abstraction-level consistency rules for Ruby code: " \
  "(1) Methods in the same class/module should operate at the same level; " \
  "(2) statements within the same method should stay at one abstraction level; " \
  "(3) fields of the same data structure should represent concepts at similar granularity; " \
  "(4) parameters of the same method should be at similar abstraction levels."
).freeze

REVIEWER_MAX_OUTPUT_TOKENS = [512, (LLMConfig::EFFECTIVE_CONTEXT_WINDOW * 0.15).to_i].min

module ReviewKnowledge
  def review_knowledge
    const_get(:REVIEW_KNOWLEDGE)
  end
end

class SecurityReviewerAgent < Phronomy::Agent::Base
  extend ReviewKnowledge
  REVIEW_KNOWLEDGE = SECURITY_CRITERIA

  agent_definition id: "example-14-security-reviewer-agent", version: 2
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
  max_output_tokens REVIEWER_MAX_OUTPUT_TOKENS
  max_iterations 1
end

class PerformanceReviewerAgent < Phronomy::Agent::Base
  extend ReviewKnowledge
  REVIEW_KNOWLEDGE = PERFORMANCE_CRITERIA

  agent_definition id: "example-14-performance-reviewer-agent", version: 2
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
  max_output_tokens REVIEWER_MAX_OUTPUT_TOKENS
  max_iterations 1
end

class ReadabilityReviewerAgent < Phronomy::Agent::Base
  extend ReviewKnowledge
  REVIEW_KNOWLEDGE = READABILITY_CRITERIA

  agent_definition id: "example-14-readability-reviewer-agent", version: 2
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
  max_output_tokens REVIEWER_MAX_OUTPUT_TOKENS
  max_iterations 1
end

class AbstractionConsistencyReviewerAgent < Phronomy::Agent::Base
  extend ReviewKnowledge
  REVIEW_KNOWLEDGE = ABSTRACTION_CRITERIA

  agent_definition id: "example-14-abstraction-consistency-reviewer-agent", version: 2
  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  context_window LLMConfig::CONTEXT_WINDOW
  instructions <<~INST
    You are a software design expert specialising in abstraction-level consistency in Ruby.
    Examine whether elements that appear at the same structural level share a
    consistent abstraction level. Check methods in a class/module, statements
    within a method, data-structure fields, and method parameters.

    For each inconsistency output exactly one line:
      [SEVERITY] line NNN — description
    Severity: HIGH / MEDIUM / LOW.
    If none found: output "No abstraction-level issues found." Be concise — findings only.
  INST
  max_output_tokens REVIEWER_MAX_OUTPUT_TOKENS
  max_iterations 1
end
