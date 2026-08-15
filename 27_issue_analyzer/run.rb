#!/usr/bin/env ruby
# frozen_string_literal: true

# 27 GitHub Issue Analyzer
#
# Two-axis classification of GitHub Issues using Phronomy::Agent::Base.
#
# Axis 1 — ISSUE TYPE: WHAT kind of issue?
# Axis 2 — COMPONENT:  WHERE in the current Phronomy architecture?
#
# The LLM identifies semantically meaningful (type, component) pairs directly,
# not the cross-product of independent type/component lists.

require_relative "../shared/llm_config"
require "phronomy"
require "fileutils"
require "json"
require "open3"
require "csv"

REPO = "Raizo-TCS/phronomy"
OPEN_ONLY = ARGV.include?("--open-only")
DRY_RUN = ARGV.include?("--dry-run")
BATCH_SIZE = 15
CSV_OUT = File.expand_path("../../docs/issue_analysis.csv", __FILE__)

ISSUE_TYPES = {
  "Bug: Correctness / Silent Failure" =>
    "wrong behavior, silent discard, nil return, incorrect logic, ignored result, key collision",
  "Bug: Concurrency / Thread Safety" =>
    "race condition, mutex, deadlock, reentrancy, lock-order violation, thread-unsafe operation",
  "Bug: Memory / Resource Leak" =>
    "memory leak, unbounded growth, resource not released",
  "Bug: Validation / Schema" =>
    "parameter validation missing, schema error, type coercion bug, invalid JSON Schema output",
  "Bug: Security Vulnerability" =>
    "injection, PII leak, trust boundary violation, data exposure",
  "Bug: Documentation Mismatch" =>
    "doc or comment says X but code does Y; stale documentation contradicts actual behavior",
  "Feature" =>
    "new capability, enhancement, new method/DSL, extended public API, new configurable option",
  "Architecture Decision" =>
    "design decision, API shape, concurrency/control-plane choice, ADR, architecture-driven refactoring",
  "Documentation" =>
    "README, CHANGELOG, YARD docs, ADR — purely documentation work",
  "Testing / CI" =>
    "missing spec, coverage gap, CI workflow, mutation testing, integration test, fault injection, stress test",
  "Security" =>
    "security hardening, PII redaction policy, prompt injection defense, tool scope enforcement, approval gate",
  "Performance / Observability" =>
    "performance improvement, metrics collection, trace quality improvement, benchmark regression",
  "Cleanup / Maintenance" =>
    "refactor, rename, deprecation, remove dead code, lint fix, dependency cleanup",
  "MCP (pending PR)" =>
    "issue explicitly blocked waiting for an MCP transport PR to merge"
}.freeze

# Current Phronomy architectural areas. These intentionally avoid removed
# scheduler/runtime-backend and StateStore models.
COMPONENTS = {
  "Runtime / EventLoop / Timer" =>
    "Runtime lifecycle, EventLoop, EventLoop-owned thread, TimerQueue, TimerService, diagnostics, shutdown",
  "Engine / FSMSession / FSM" =>
    "FSMSession, generic FSM/state machine, event dispatch, session registration, lifecycle continuation",
  "Cancellation / Deadline" =>
    "CancellationToken, CancellationScope, Deadline, timeout propagation and cancellation semantics",
  "OffloadPool / Concurrency" =>
    "OffloadPool, PoolRegistry, bounded synchronous-work isolation, backpressure, AsyncQueue",
  "Agent Execution / Context" =>
    "Agent::Base, AgentExecution, AgentInvocation, ExecutionCoordinator, Journal, Knowledge, transcript, context lifecycle",
  "Tool / ToolInvocation" =>
    "Tool capability contract, ToolInvocation, ToolExecutor, execution_mode, approval and tool-result handling",
  "MultiAgent / FanOut / Handoff" =>
    "MultiAgent::Orchestrator, FanOut FSMSession, max_concurrency, Agent-as-Tool, handoff, TeamCoordinator",
  "Workflow / Durable State" =>
    "Workflow, WorkflowContext, workflow_states, wait states, signals, state transitions, thread_id admission",
  "Persistence / ContentStore" =>
    "Persistence protocol/backends, workflow_states, ContentStore, Agent Journal durability, optimistic revisions, restore/load behavior",
  "Context Policy / Manifest / LLM Adapter" =>
    "ContextPolicy, ContextAssembler, candidates, token budget, LLMInputManifest, provider materialization, LLM adapters",
  "RAG / VectorStore" =>
    "VectorStore, embeddings, loaders, splitters, vector search and RAG integration",
  "Tracing / Observability" =>
    "Tracing::Base, spans, diagnostics, metrics, trace quality and observability",
  "Filter / Trust / Approval" =>
    "Filter, input/output/tool-result filtering, GeneratorVerifier, approval policy and trust boundaries",
  "MCP / Transport" =>
    "MCP tool integration, stdio/HTTP transport, JSON-RPC and MCP protocol handling",
  "Output Parsing / Prompt" =>
    "OutputParser, prompt templates/instructions, structured output and parsing",
  "Public API / Configuration" =>
    "Phronomy.configure, public interface contract, gemspec, version constant and compatibility surface",
  "Testing / CI" =>
    "Phronomy::Testing, test-only Eval support, RSpec, CI workflow, mutation testing and test helpers",
  "Cross-cutting / Framework-wide" =>
    "issues touching multiple areas or fundamental design spanning the framework"
}.freeze

TYPE_NAMES = ISSUE_TYPES.keys.freeze
COMP_NAMES = COMPONENTS.keys.freeze

TYPE_ABBR = {
  "Bug: Correctness / Silent Failure" => "Bug:Correct",
  "Bug: Concurrency / Thread Safety" => "Bug:Concurr",
  "Bug: Memory / Resource Leak" => "Bug:MemLeak",
  "Bug: Validation / Schema" => "Bug:Valid  ",
  "Bug: Security Vulnerability" => "Bug:SecVuln",
  "Bug: Documentation Mismatch" => "Bug:DocMism",
  "Feature" => "Feature    ",
  "Architecture Decision" => "ArchDec    ",
  "Documentation" => "Docs       ",
  "Testing / CI" => "Test/CI    ",
  "Security" => "Security   ",
  "Performance / Observability" => "Perf/Obs   ",
  "Cleanup / Maintenance" => "Cleanup    ",
  "MCP (pending PR)" => "MCP-PR     "
}.freeze

COMP_ABBR = {
  "Runtime / EventLoop / Timer" => "RT",
  "Engine / FSMSession / FSM" => "FS",
  "Cancellation / Deadline" => "CL",
  "OffloadPool / Concurrency" => "OF",
  "Agent Execution / Context" => "AG",
  "Tool / ToolInvocation" => "TL",
  "MultiAgent / FanOut / Handoff" => "MA",
  "Workflow / Durable State" => "WF",
  "Persistence / ContentStore" => "PS",
  "Context Policy / Manifest / LLM Adapter" => "CX",
  "RAG / VectorStore" => "RG",
  "Tracing / Observability" => "TR",
  "Filter / Trust / Approval" => "FT",
  "MCP / Transport" => "MC",
  "Output Parsing / Prompt" => "OP",
  "Public API / Configuration" => "PA",
  "Testing / CI" => "CI",
  "Cross-cutting / Framework-wide" => "XC"
}.freeze

TYPE_LIST = ISSUE_TYPES.map.with_index(1) do |(name, hint), i|
  "  #{i}. #{name}\n     (#{hint})"
end.join("\n")

COMP_LIST = COMPONENTS.map.with_index(1) do |(name, hint), i|
  "  #{i}. #{name}\n     (#{hint})"
end.join("\n")

class IssueClassifierAgent < Phronomy::Agent::Base
  agent_definition id: "example-27-issue-classifier-agent", version: 2

  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER

  instructions <<~PROMPT
    You are classifying GitHub Issues for "phronomy" on TWO INDEPENDENT axes.
    The axes are ORTHOGONAL — issue types describe WHAT the issue is, components
    describe WHERE in the current codebase it applies. Do NOT mix them.

    ── Axis 1: TYPES — WHAT kind of issue? ──
    #{TYPE_LIST}

    ── Axis 2: COMPONENTS — WHERE in the current architecture? ──
    #{COMP_LIST}

    ── Rules ─────────────────────────────────────────────────────────────────
    Each issue produces one or more SEMANTICALLY MEANINGFUL (type, component)
    pairs. Identify all distinct aspects of the issue.

    IMPORTANT: Do NOT take the cross-product of types × components.

    Example — an issue that adds a Runtime timer feature and fixes a stale Agent
    lifecycle comment:
      pairs: [{"type":"Feature","component":"Runtime / EventLoop / Timer"},
              {"type":"Bug: Documentation Mismatch","component":"Agent Execution / Context"}]

    - Use ONLY the exact type and component names listed above.
    - "Bug: Documentation Mismatch" means code is correct but docs/comments contradict it.
    - "Documentation" means purely documentation work.
    - "Architecture Decision" means a design choice and may coexist with another type.
    - If a component is unclear, use "Cross-cutting / Framework-wide".

    Respond with ONLY valid JSON (no markdown, no explanation):
    {"results": [{"number": 123, "pairs": [{"type": "Feature", "component": "Runtime / EventLoop / Timer"}, {"type": "Architecture Decision", "component": "Engine / FSMSession / FSM"}]}]}
  PROMPT
end

puts "Fetching issues from #{REPO}..."
state_flag = OPEN_ONLY ? "--state open" : "--state all"
out, err, status = Open3.capture3(
  "gh issue list --repo #{REPO} #{state_flag} --limit 500 " \
  "--json number,title,state,labels,closedAt"
)
unless status.success?
  warn "gh command failed: #{err.strip}"
  warn "Set GH_TOKEN or run 'gh auth login' to enable issue fetching."
  warn "Skipping analysis (exit 0)."
  exit 0
end

issues = JSON.parse(out)
open_total = issues.count { |i| i["state"] == "OPEN" }
closed_total = issues.count { |i| i["state"] == "CLOSED" }
puts "Fetched #{issues.size} issues (open: #{open_total}, closed: #{closed_total})"
puts

issue_pairs = {}
parse_error_count = 0

if DRY_RUN
  puts "[dry-run] Skipping LLM — all issues left as unclassified."
  issues.each do |i|
    issue_pairs[i["number"]] = [["(unclassified)", "(unclassified)"]]
  end
else
  batches = issues.each_slice(BATCH_SIZE).to_a

  batches.each_with_index do |batch, idx|
    payload = batch.map do |i|
      {
        number: i["number"],
        title: i["title"],
        labels: i["labels"].map { |l| l["name"] }
      }
    end
    range_str = "#{batch.first["number"]}..#{batch.last["number"]}"
    print "  Batch #{idx + 1}/#{batches.size} (##{range_str})... "
    $stdout.flush

    begin
      # run_once creates a fresh Agent per batch so history never bleeds across batches.
      result = Phronomy::Agent.run_once(definition: IssueClassifierAgent, input: payload.to_json)
      raw = result[:output].to_s.strip
        .gsub(/\A```(?:json)?\n?/, "")
        .gsub(/\n?```\z/, "")
        .strip
      parsed = JSON.parse(raw)
      parsed["results"].each do |r|
        pairs = Array(r["pairs"]).filter_map do |p|
          type = p["type"]
          component = p["component"]
          [type, component] if ISSUE_TYPES.key?(type) && COMPONENTS.key?(component)
        end
        issue_pairs[r["number"]] = pairs.empty? ?
          [["(unrecognized)", "Cross-cutting / Framework-wide"]] : pairs
      end
      puts "OK (#{batch.size} classified)"
    rescue JSON::ParserError => e
      puts "PARSE ERROR: #{e.message[0, 60]}"
      parse_error_count += batch.size
      batch.each { |i| issue_pairs[i["number"]] = [["(parse error)", "(parse error)"]] }
    rescue => e
      puts "ERROR: #{e.class}: #{e.message[0, 60]}"
      parse_error_count += batch.size
      batch.each { |i| issue_pairs[i["number"]] = [["(error)", "(error)"]] }
    end
  end

  puts "\nClassification complete: #{issues.size} issues in #{batches.size} batches."
  puts "  Parse/error count: #{parse_error_count}" if parse_error_count.positive?
  puts
end

FALLBACK_PAIR = [["(unclassified)", "(unclassified)"]].freeze

by_type = Hash.new { |h, k| h[k] = [] }
issues.each do |issue|
  (issue_pairs[issue["number"]] || FALLBACK_PAIR).map(&:first).uniq.each do |type|
    by_type[type] << issue
  end
end

by_comp = Hash.new { |h, k| h[k] = [] }
issues.each do |issue|
  (issue_pairs[issue["number"]] || FALLBACK_PAIR).map(&:last).uniq.each do |component|
    by_comp[component] << issue
  end
end

hist = Hash.new { |h, k| h[k] = Hash.new(0) }
issues.each do |issue|
  (issue_pairs[issue["number"]] || FALLBACK_PAIR).each do |type, component|
    hist[type][component] += 1
  end
end

begin
  FileUtils.mkdir_p(File.dirname(CSV_OUT))
  CSV.open(CSV_OUT, "w") do |csv|
    csv << %w[number state title type component]
    issues.each do |issue|
      (issue_pairs[issue["number"]] || FALLBACK_PAIR).each do |type, component|
        csv << [issue["number"], issue["state"], issue["title"], type, component]
      end
    end
  end
  puts "CSV written → #{CSV_OUT}"
rescue => e
  warn "CSV write failed: #{e.message}"
end
puts

BAR_W = 20

def pbar(closed, total)
  pct = total.zero? ? 0.0 : closed.fdiv(total)
  fill = (pct * BAR_W).round
  "#{"█" * fill}#{"░" * (BAR_W - fill)} #{format("%3.0f%%", pct * 100)}"
end

SEP = "═" * 92
THIN = "─" * 92

puts SEP
puts "  phronomy Issue Analysis  |  #{REPO}  |  #{LLMConfig::MODEL}"
puts "  Axes: (1) Issue Type = WHAT  ×  (2) Architectural Component = WHERE"
puts SEP
puts
puts "  SECTION 1 — Issue Type Breakdown  (Axis 1: WHAT kind of issue?)"
puts "  " + THIN

valid_types = TYPE_NAMES.select { |type| by_type.key?(type) }
valid_types.each do |type|
  list = by_type[type]
  total = list.size
  closed = list.count { |issue| issue["state"] == "CLOSED" }
  open = total - closed
  puts format("  %-38s %3d  open:%-2d  %s", type, total, open, pbar(closed, total))
end

["(parse error)", "(error)", "(unrecognized)", "(unclassified)"].each do |type|
  next unless by_type.key?(type)

  list = by_type[type]
  puts format(
    "  %-38s %3d  open:%-2d  (excluded from histogram)",
    type,
    list.size,
    list.count { |issue| issue["state"] == "OPEN" }
  )
end

puts
puts format(
  "  %-38s %3d  open:%-2d  %s",
  "TOTAL (unique issues)",
  issues.size,
  open_total,
  pbar(closed_total, issues.size)
)

puts
puts "  SECTION 2 — Architectural Component Breakdown  (Axis 2: WHERE?)"
puts "  " + THIN
puts

valid_comps = COMP_NAMES.select { |component| by_comp.key?(component) }
valid_comps.each do |component|
  list = by_comp[component]
  total = list.size
  closed = list.count { |issue| issue["state"] == "CLOSED" }
  open = total - closed
  puts format("  %-38s %3d  open:%-2d  %s", component, total, open, pbar(closed, total))
end

puts
puts "  SECTION 3 — 2D Histogram: Issue Type × Architectural Component"
puts "  (cell = count of meaningful (type, component) pairs — NOT a cross-product)"
puts "  (Section 1 & 2 counts = unique issues; Section 3 counts = semantic pairs)"
puts "  " + THIN
puts

puts "  Component abbreviations:"
COMP_NAMES.each_slice(2) do |pair|
  puts "    " + pair.map { |component| format("%-3s = %-39s", COMP_ABBR[component], component) }.join("  ")
end
puts

col_header = "              " +
  COMP_NAMES.map { |component| format(" %3s", COMP_ABBR[component]) }.join +
  "  Total"
puts col_header
puts "  " + "─" * (col_header.length - 2)

row_totals = TYPE_NAMES.map do |type|
  [type, COMP_NAMES.sum { |component| hist[type][component] }]
end

row_totals.each do |type, row_total|
  next if row_total.zero?

  cells = COMP_NAMES.map { |component| format(" %3d", hist[type][component]) }.join
  abbr = (TYPE_ABBR[type] || type[0, 11]).strip
  puts format("  %-12s", abbr) + cells + format("  %5d", row_total)
end

col_sums = COMP_NAMES.map { |component| TYPE_NAMES.sum { |type| hist[type][component] } }
puts "  " + "─" * (col_header.length - 2)
puts "  Total       " +
  col_sums.map { |sum| format(" %3d", sum) }.join +
  format("  %5d", col_sums.sum)
puts

open_issues = issues.select { |issue| issue["state"] == "OPEN" }
if open_issues.any?
  puts "  SECTION 4 — Open Issues (#{open_issues.size})"
  puts "  " + THIN
  puts
  open_issues.sort_by { |issue| issue["number"] }.each do |issue|
    labels = issue["labels"].map { |label| label["name"] }.join(", ")
    pairs = issue_pairs[issue["number"]] || []
    puts "  ##{issue["number"]}  #{issue["title"]}"
    puts "    Labels: #{labels.empty? ? "(none)" : labels}"
    pairs.each { |type, component| puts "    (#{type})  →  #{component}" }
    puts
  end
end

puts "  SECTION 5 — Issue Volume by Period"
puts "  " + THIN
[
  ["#2-50    Initial features + first bugs", 2..50],
  ["#51-100  Code quality + docs round 1", 51..100],
  ["#101-150 Runtime / Workflow / docs", 101..150],
  ["#151-200 Deep docs audit", 151..200],
  ["#201-260 Concurrency architecture planning", 201..260],
  ["#261-320 Cooperative architecture implementation", 261..320],
  ["#321-383 ADR/runtime cleanup / lint / CI", 321..383]
].each do |label, range|
  group = issues.select { |issue| range.cover?(issue["number"]) }
  next if group.empty?

  closed = group.count { |issue| issue["state"] == "CLOSED" }
  puts format("  %-46s %3d issues  %s", label, group.size, pbar(closed, group.size))
end
puts SEP
