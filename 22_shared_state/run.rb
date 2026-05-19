# frozen_string_literal: true

# 22 Shared State -- Collaborative Code Review Team
#
# Three specialist agents -- StructureAnalyst, SecurityAuditor, QualityReviewer --
# collaborate via a shared KnowledgeStore to produce a multi-perspective code review.
# Each agent reads what peers have already found before writing its own findings.
#
# Demonstrates: researchers, max_cycles, terminate_when, aggregate,
#               custom tools (list_files + read_file), human-in-the-loop approval.

require_relative "../shared/llm_config"
require "phronomy"
require_relative "tools"

# ---------------------------------------------------------------------------
# Researcher agents -- each has a different code-review lens
# ---------------------------------------------------------------------------
class StructureAnalyst < Phronomy::Agent::Base
  model        LLMConfig::MODEL
  provider     LLMConfig::PROVIDER
  tools        ListFilesTool, ReadFileTool
  instructions <<~INST
    You are a software architect reviewing a Ruby codebase.
    Use list_files to discover all available files, then use read_file to read each one.
    For each file, record one finding describing:
    - The class or module responsibilities and whether they are well-separated
    - Any coupling or dependencies you observe between classes
    - The overall design pattern (e.g. service object, god class, utility class)
    Submit exactly one sentence per file via write_finding.
  INST
end

class SecurityAuditor < Phronomy::Agent::Base
  model        LLMConfig::MODEL
  provider     LLMConfig::PROVIDER
  tools        ListFilesTool, ReadFileTool
  instructions <<~INST
    You are a security engineer auditing a Ruby codebase.
    Use list_files, then use read_file to inspect each file carefully.
    Look for these vulnerabilities:
    - SQL injection: user input interpolated directly into query strings
    - Hardcoded credentials: API keys, passwords, or tokens as constants
    - SSL verification disabled: VERIFY_NONE or equivalent
    - Missing input validation before using user-supplied values
    Submit exactly one sentence per vulnerability found via write_finding.
    If a file has no issues, skip it and move to the next.
  INST
end

class QualityReviewer < Phronomy::Agent::Base
  model        LLMConfig::MODEL
  provider     LLMConfig::PROVIDER
  tools        ListFilesTool, ReadFileTool
  instructions <<~INST
    You are a code quality reviewer analyzing a Ruby codebase.
    Use list_files, then use read_file for each file.
    Look for these quality issues:
    - Code duplication: identical or near-identical method bodies
    - Magic numbers: unexplained numeric literals (e.g. 500, 25)
    - Overly long methods: methods with more than 10 lines
    - Missing error handling: risky operations with no rescue
    Submit exactly one sentence per issue found via write_finding.
  INST
end

# ---------------------------------------------------------------------------
# Review team -- shared state coordinates the three reviewers
# ---------------------------------------------------------------------------
class CodeReviewTeam < Phronomy::Agent::SharedState
  researchers StructureAnalyst, SecurityAuditor, QualityReviewer

  max_cycles 3

  aggregate do |store|
    report = store.read_all
      .group_by { |f| f[:agent] }
      .map do |agent, findings|
        items = findings.map { |f| "  (cycle #{f[:cycle]}) #{f[:content]}" }.join("\n")
        "[ #{agent} ]\n#{items}"
      end
      .join("\n\n")
    { report: report, count: store.size }
  end
end

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
target_dir = ARGV[0] || File.expand_path("./data", __dir__)

puts "=== Shared State Code Review Example ==="
puts "Target : #{target_dir}"

# Human-in-the-loop: ask once before any LLM call
DirectoryAccess.ask_user!(target_dir)

result = CodeReviewTeam.new.invoke("Review the Ruby source files in: #{target_dir}")

puts result[:output][:report]
puts
puts "-" * 50
puts "Cycles completed : #{result[:cycles]}"
puts "Terminated by    : #{result[:terminated_by]}"
puts "Total findings   : #{result[:output][:count]}"
