# frozen_string_literal: true

# 22 Shared State -- Collaborative Code Review Team
#
# Three specialist agents -- StructureAnalyst, SecurityAuditor, QualityReviewer --
# collaborate via a shared KnowledgeStore to produce a multi-perspective code review.
# Each agent reads what peers have already found before writing its own findings.
#
# Demonstrates: member (with per-agent instruction), coordination, max_cycles,
#               aggregate, custom tools (list_files + read_file), human-in-the-loop.

require_relative "../shared/llm_config"
require "phronomy"
require_relative "tools"

# ---------------------------------------------------------------------------
# Member agents -- each has a different code-review lens
# Agent instructions cover domain expertise only; coordination protocol is
# defined by the Team below via `coordination` and `member instruction:`.
# ---------------------------------------------------------------------------
class StructureAnalyst < Phronomy::Agent::Base
  model        LLMConfig::MODEL
  provider     LLMConfig::PROVIDER
  tools        ListFilesTool, ReadFileTool
  instructions <<~INST
    You are a software architect reviewing a Ruby codebase.
    Use list_files to discover all available files, then use read_file to read each one.
    For each file, identify class/module responsibilities, coupling, and design patterns.
  INST
end

class SecurityAuditor < Phronomy::Agent::Base
  model        LLMConfig::MODEL
  provider     LLMConfig::PROVIDER
  tools        ListFilesTool, ReadFileTool
  instructions <<~INST
    You are a security engineer auditing a Ruby codebase.
    Use list_files, then use read_file to inspect each file carefully.
    Look for SQL injection, hardcoded credentials, disabled SSL, and missing input validation.
  INST
end

class QualityReviewer < Phronomy::Agent::Base
  model        LLMConfig::MODEL
  provider     LLMConfig::PROVIDER
  tools        ListFilesTool, ReadFileTool
  instructions <<~INST
    You are a code quality reviewer analyzing a Ruby codebase.
    Use list_files, then use read_file for each file.
    Look for code duplication, magic numbers, overly long methods, and missing error handling.
  INST
end

# ---------------------------------------------------------------------------
# Review team -- coordination protocol and per-agent focus defined here
# ---------------------------------------------------------------------------
class CodeReviewTeam < Phronomy::Agent::SharedState
  # Team-level coordination protocol: all members receive this instead of the
  # built-in default guide.
  coordination <<~COORD
    You are part of a collaborative code review team sharing a knowledge store.
    Two tools coordinate your work:
      read_store     -- returns all current findings as JSON (no parameters)
      write_finding  -- records one finding to the store (param: content)
    You also have access to list_files and read_file to inspect source files.
    Required workflow: call read_store first, then call write_finding once per insight.
    Each write_finding call must contain exactly one unique insight.
    If you have no new insights, call write_finding exactly once with: "No new findings in this cycle."
    Do not output plain text -- every insight must be submitted via write_finding.
  COORD

  # Per-agent instruction narrows each member's focus without changing their
  # core expertise instructions defined in the agent class above.
  member StructureAnalyst
  member SecurityAuditor,  instruction: "If a file has no security issues, skip it and move to the next file."
  member QualityReviewer,  instruction: "Flag each issue in its own finding; do not bundle multiple issues."

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
