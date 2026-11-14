# frozen_string_literal: true

require_relative "../shared/llm_config"
require_relative "tools"
require_relative "adaptive_shared_state"

class StructureAnalyst < Phronomy::Agent::Base
  agent_definition id: "example-22-structure-analyst", version: 2

  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  tools(
    ListFilesTool => nil,
    ReadFileTool => nil
  )
  instructions <<~INST
    You are a software architect reviewing a Ruby codebase.
    Use list_files to discover all available files, then use read_file to read each one.
    For each file, identify class/module responsibilities, coupling, and design patterns.
  INST
end

class SecurityAuditor < Phronomy::Agent::Base
  agent_definition id: "example-22-security-auditor", version: 2

  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  tools(
    ListFilesTool => nil,
    ReadFileTool => nil
  )
  instructions <<~INST
    You are a security engineer auditing a Ruby codebase.
    Use list_files, then use read_file to inspect each file carefully.
    Look for SQL injection, hardcoded credentials, disabled SSL, and missing input validation.
  INST
end

class QualityReviewer < Phronomy::Agent::Base
  agent_definition id: "example-22-quality-reviewer", version: 2

  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  tools(
    ListFilesTool => nil,
    ReadFileTool => nil
  )
  instructions <<~INST
    You are a code quality reviewer analyzing a Ruby codebase.
    Use list_files, then use read_file for each file.
    Look for code duplication, magic numbers, overly long methods, and missing error handling.
  INST
end

class CodeReviewTeam
  COORDINATION = <<~COORD
    You are part of a collaborative code review team sharing a knowledge store.
    Two tools coordinate your work:
      read_store     -- requests a budgeted page of shared findings
      write_finding  -- records one finding to the store (param: content)
    read_store returns a request receipt. The next LLM input includes its matching
    shared_findings_page knowledge, identified by tool_call_id. Read the page there.
    Page sizes adapt to the loaded context window and the complete Tool exchange.
    Records contain stable IDs and complete text when it fits in the response budget.
    Use next_before_id as before_id to continue to older records.
    Use read_store with query (such as a filename) to find relevant findings.
    If a record is truncated, use its id as finding_id and next_content_offset as content_offset
    to retrieve the rest. Do not treat a truncated record as the complete finding.
    Multiple read_store requests share the available retrieval budget. Prefer one
    request at a time when you need a larger page. Each request reads the findings
    that existed when that request executed, including writes completed before it.
    You also have access to list_files and read_file to inspect source files.
    Required workflow: call read_store first, then call write_finding once per insight.
    Each write_finding call must contain exactly one unique insight.
    If you have no new insights, call write_finding exactly once with: "No new findings in this cycle."
    Do not output plain text -- every insight must be submitted via write_finding.
  COORD

  # Each call has independent sharing, policy instances and derived reviewers.
  def invoke(input, config: {})
    sharing = ReviewSharing.new
    team = Class.new(Phronomy::MultiAgent::SharedState)
    team.sharing(sharing, id: "example-22-review-findings", version: 3)
    team.coordination(COORDINATION)
    team.member(sharing.prepare_member(StructureAnalyst))
    team.member(sharing.prepare_member(SecurityAuditor),
      instruction: "If a file has no security issues, skip it and move to the next file.")
    team.member(sharing.prepare_member(QualityReviewer),
      instruction: "Flag each issue in its own finding; do not bundle multiple issues.")
    team.max_cycles(3)
    team.aggregate { |store| aggregate_findings(store) }
    team.new.invoke(input, config: config)
  end

  private

  def aggregate_findings(store)
    report = store.read_all
      .group_by { |finding| finding[:agent] }
      .map do |agent, findings|
        items = findings.map { |finding|
          "  (cycle #{finding[:cycle]}) #{finding[:content]}"
        }.join("\n")
        "[ #{agent} ]\n#{items}"
      end
      .join("\n\n")

    {report: report, count: store.size}
  end
end
