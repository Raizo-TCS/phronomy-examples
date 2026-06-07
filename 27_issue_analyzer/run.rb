#!/usr/bin/env ruby
# frozen_string_literal: true

# 27 GitHub Issue Analyzer
#
# Two-axis classification of GitHub Issues using Phronomy::Agent::Base.
#
# Axis 1 — ISSUE TYPE  : WHAT kind of issue (Bug/Feature/Docs/Test etc.)
#                        — purely issue-nature; no component names here
# Axis 2 — COMPONENT   : WHERE in the codebase (module / layer / subsystem)
#                        — purely structural location; no issue-kind names here
#
# Each issue is a point (or set of points) in TYPE × COMPONENT 2D space.
# Multiple types/components per issue are allowed (multi-label).
# The LLM identifies semantically meaningful (type, component) pairs directly —
# NOT the cross-product of independent type/component lists.
#
# Output:
#   • Terminal: Section 1 = 1D type totals
#               Section 2 = 1D component totals
#               Section 3 = 2D histogram (TYPE rows × COMPONENT cols)
#               Section 4 = Open issues detail
#               Section 5 = Issue volume by period
#   • CSV: docs/issue_analysis.csv  (one row per issue×type×component triple)
#
# Run:
#   bundle exec ruby 27_issue_analyzer/run.rb [--open-only] [--dry-run]
#
# Prerequisites:
#   - gh (GitHub CLI) installed and authenticated
#   - LLM configured via environment variables (see shared/llm_config.rb)

require_relative "../shared/llm_config"
require "phronomy"
require "json"
require "open3"
require "csv"

# ===========================================================================
# Configuration — edit these to point at your own repository
# ===========================================================================
REPO       = "Raizo-TCS/phronomy"
OPEN_ONLY  = ARGV.include?("--open-only")
DRY_RUN    = ARGV.include?("--dry-run")
BATCH_SIZE = 15
CSV_OUT    = File.expand_path("../../docs/issue_analysis.csv", __FILE__)

# ===========================================================================
# Axis 1: ISSUE_TYPES — WHAT kind of issue is it?
# (purely describes the nature of the work; no component/module names here)
# ===========================================================================
ISSUE_TYPES = {
  "Bug: Correctness / Silent Failure" =>
    "wrong behavior, silent discard, nil return, incorrect logic, ignored result, key collision",
  "Bug: Concurrency / Thread Safety"  =>
    "race condition, mutex, deadlock, reentrancy, lock-order violation, thread-unsafe operation",
  "Bug: Memory / Resource Leak"       =>
    "memory leak, unbounded growth, zombie process, orphan thread, resource not released",
  "Bug: Validation / Schema"          =>
    "parameter validation missing, schema error, type coercion bug, invalid JSON Schema output",
  "Bug: Security Vulnerability"       =>
    "injection, PII leak, trust boundary violation, data exposure",
  "Bug: Documentation Mismatch"       =>
    "doc or comment says X but code does Y; stale YARD description contradicts actual behavior",
  "Feature"                           =>
    "new capability, enhancement, new method/DSL, extended public API, new configurable option",
  "Architecture Decision"             =>
    "design decision, API shape, concurrency model choice, ADR write-up, refactoring driven by design",
  "Documentation"                     =>
    "README, CHANGELOG, YARD docs, ADR — PURELY documentation work, no code change required",
  "Testing / CI"                      =>
    "missing spec, coverage gap, CI workflow, mutation testing, integration test, fault injection, stress test",
  "Security"                          =>
    "security hardening, PII redaction policy, prompt injection defense, tool scope enforcement, approval gate",
  "Performance / Observability"       =>
    "performance improvement, O(n) fix, metrics collection, trace quality improvement, benchmark regression",
  "Cleanup / Maintenance"             =>
    "refactor, rename, deprecation, remove dead code, lint fix, allowlist cleanup",
  "MCP (pending PR)"                  =>
    "issue explicitly blocked waiting for MCP transport PR to merge; cannot close until that PR lands",
}.freeze

# ===========================================================================
# Axis 2: COMPONENTS — WHERE in the codebase does it touch?
# (purely structural location; no issue-kind / work-type names here)
# ===========================================================================
COMPONENTS = {
  "Runtime / Scheduler / Task"     =>
    "Runtime, Task, Scheduler, FiberScheduler, ImmediateBackend, ThreadBackend, AsyncQueue, TimerQueue, runtime_backend config",
  "EventLoop / ConcurrencyGate"    =>
    "EventLoop, ConcurrencyGate, InvocationContext, TaskGroup, structured concurrency primitives",
  "Cancellation / Deadline"        =>
    "CancellationToken, CancellationScope, Deadline, invoke_timeout, timeout propagation through call stack",
  "BlockingAdapterPool"            =>
    "BlockingAdapterPool, blocking I/O isolation, GVL-aware thread pool, future/promise for blocking gems",
  "Agent / FSM"                    =>
    "Agent::Base, AgentFSM, ReactAgent, before_completion hook, agent lifecycle state machine, tool-call loop",
  "Tool / ToolExecutor"            =>
    "Tool::Base, ToolExecutor, execution_mode routing (blocking_io/cooperative/cpu_bound), tool JSON schema",
  "Orchestrator / Multi-agent"     =>
    "Orchestrator, dispatch_parallel, handoff, multi-agent coordination, TeamCoordinator, sub-agent invocation",
  "Workflow / Graph"               =>
    "WorkflowContext, WorkflowRunner, Graph DSL, parallel_node, subgraph, state machine node transitions",
  "Memory / Context Management"    =>
    "ConversationManager, ContextVersionCache, TokenEstimator, BufferedMemory, context budget, message history",
  "RAG / VectorStore"              =>
    "VectorStore, Embeddings, KnowledgeSource, pgvector, Redis vector, semantic search, RAG pipeline",
  "Tracing / Observability"        =>
    "Tracing::Base, LangfuseTracer, OpenTelemetry, trace tree, span recording, trace_pii, metrics",
  "Security / Guardrails"          =>
    "Guardrail, InputGuardrail, OutputGuardrail, TrustPipeline, PiiPatternDetector, approval gate",
  "MCP / Transport"                =>
    "McpTool, StdioTransport, HttpTransport, JSON-RPC over stdio/HTTP, MCP protocol, startup_timeout",
  "Chain / Prompt"                 =>
    "Chain::Base, PromptTemplate, LLMChain, OutputParser, streaming chain, prompt variable rendering",
  "Public API / Configuration"     =>
    "Phronomy.configure, public interface contract, gemspec, version constant, @api tag enforcement",
  "CI / Testing Infrastructure"    =>
    "CI workflow .yml files, RSpec configuration, mutant mutation testing, SimpleCov, test support helpers",
  "Cross-cutting / Framework-wide" =>
    "issues touching multiple components simultaneously, or fundamental design spanning the entire framework",
}.freeze

TYPE_NAMES = ISSUE_TYPES.keys.freeze
COMP_NAMES = COMPONENTS.keys.freeze

# Short abbreviations for the 2D histogram header row
TYPE_ABBR = {
  "Bug: Correctness / Silent Failure" => "Bug:Correct",
  "Bug: Concurrency / Thread Safety"  => "Bug:Concurr",
  "Bug: Memory / Resource Leak"       => "Bug:MemLeak",
  "Bug: Validation / Schema"          => "Bug:Valid  ",
  "Bug: Security Vulnerability"       => "Bug:SecVuln",
  "Bug: Documentation Mismatch"       => "Bug:DocMism",
  "Feature"                           => "Feature    ",
  "Architecture Decision"             => "ArchDec    ",
  "Documentation"                     => "Docs       ",
  "Testing / CI"                      => "Test/CI    ",
  "Security"                          => "Security   ",
  "Performance / Observability"       => "Perf/Obs   ",
  "Cleanup / Maintenance"             => "Cleanup    ",
  "MCP (pending PR)"                  => "MCP-PR     ",
}.freeze

COMP_ABBR = {
  "Runtime / Scheduler / Task"     => "RT",
  "EventLoop / ConcurrencyGate"    => "EL",
  "Cancellation / Deadline"        => "CL",
  "BlockingAdapterPool"            => "BP",
  "Agent / FSM"                    => "AG",
  "Tool / ToolExecutor"            => "TL",
  "Orchestrator / Multi-agent"     => "OR",
  "Workflow / Graph"               => "WF",
  "Memory / Context Management"    => "MM",
  "RAG / VectorStore"              => "RG",
  "Tracing / Observability"        => "TR",
  "Security / Guardrails"          => "SC",
  "MCP / Transport"                => "MC",
  "Chain / Prompt"                 => "CH",
  "Public API / Configuration"     => "PA",
  "CI / Testing Infrastructure"    => "CI",
  "Cross-cutting / Framework-wide" => "XC",
}.freeze

TYPE_LIST = ISSUE_TYPES.map.with_index(1) do |(name, hint), i|
  "  #{i}. #{name}\n     (#{hint})"
end.join("\n")

COMP_LIST = COMPONENTS.map.with_index(1) do |(name, hint), i|
  "  #{i}. #{name}\n     (#{hint})"
end.join("\n")

# ---------------------------------------------------------------------------
# Classification agent
# ---------------------------------------------------------------------------
class IssueClassifierAgent < Phronomy::Agent::Base
  model    LLMConfig::MODEL
  provider LLMConfig::PROVIDER

  instructions <<~PROMPT
    You are classifying GitHub Issues for "phronomy" on TWO INDEPENDENT axes.
    The axes are ORTHOGONAL — issue types describe WHAT the issue is, components
    describe WHERE in the codebase it applies.  Do NOT mix them.

    ── Axis 1: TYPES — WHAT kind of issue? (no component/module names here) ──
    #{TYPE_LIST}

    ── Axis 2: COMPONENTS — WHERE in the codebase? (no issue-kind names here) ──
    #{COMP_LIST}

    ── Rules ─────────────────────────────────────────────────────────────────
    Each issue produces one or more SEMANTICALLY MEANINGFUL (type, component)
    pairs.  Identify all distinct "aspects" of the issue, where each aspect is
    one specific kind-of-work applied to one specific place in the codebase.

    IMPORTANT: Do NOT take the cross-product of types × components.
    Instead, assign each (type, component) pair only when BOTH apply together
    to a single coherent aspect of the issue.

    Example — an issue that adds a feature to Runtime AND fixes a stale doc comment
    in Agent::Base:
      pairs: [{"type":"Feature","component":"Runtime / Scheduler / Task"},
              {"type":"Bug: Documentation Mismatch","component":"Agent / FSM"}]
    NOT the cross-product:
      types:["Feature","Bug: Documentation Mismatch"] × components:["Runtime...","Agent / FSM"]

    - Use ONLY the exact type and component names listed above — no paraphrasing.
    - TYPES must not contain component/module words; use only the type labels.
    - COMPONENTS must not contain issue-kind words; use only component labels.
    - "Bug: Documentation Mismatch" = code is correct but the doc contradicts it.
    - "Documentation" = PURELY doc work, no code change needed.
    - "Architecture Decision" = design choice; assign regardless of whether also a bug.
    - "MCP (pending PR)" = issue explicitly blocked on the MCP transport PR.
    - If a component is unclear, use "Cross-cutting / Framework-wide".

    Respond with ONLY valid JSON (no markdown, no explanation):
    {"results": [{"number": 123, "pairs": [{"type": "Feature", "component": "Runtime / Scheduler / Task"}, {"type": "Architecture Decision", "component": "EventLoop / ConcurrencyGate"}]}, ...]}
  PROMPT
end

# ---------------------------------------------------------------------------
# Fetch issues from GitHub
# ---------------------------------------------------------------------------
puts "Fetching issues from #{REPO}..."
state_flag = OPEN_ONLY ? "--state open" : "--state all"
out, err, status = Open3.capture3(
  "gh issue list --repo #{REPO} #{state_flag} --limit 500 " \
  "--json number,title,state,labels,closedAt"
)
unless status.success?
  warn "gh command failed: #{err}"
  exit 1
end

issues       = JSON.parse(out)
open_total   = issues.count { |i| i["state"] == "OPEN" }
closed_total = issues.count { |i| i["state"] == "CLOSED" }
puts "Fetched #{issues.size} issues (open: #{open_total}, closed: #{closed_total})"
puts

# ---------------------------------------------------------------------------
# Classify via Phronomy agent (batched)
# ---------------------------------------------------------------------------
# issue_pairs[number] = [[type, component], ...]
# Each pair is a semantically meaningful annotation — NOT the cross-product of
# types × components.  One issue typically has 1-3 pairs; each pair captures
# one distinct "aspect" of the issue (a kind-of-work + a place in the code).
issue_pairs        = {}
parse_error_count  = 0

if DRY_RUN
  puts "[dry-run] Skipping LLM — all issues left as unclassified."
  issues.each do |i|
    issue_pairs[i["number"]] = [["(unclassified)", "(unclassified)"]]
  end
else
  Phronomy.configure { |c| c.runtime_backend = :thread }
  agent   = IssueClassifierAgent.new
  batches = issues.each_slice(BATCH_SIZE).to_a

  batches.each_with_index do |batch, idx|
    payload = batch.map do |i|
      { number: i["number"], title: i["title"],
        labels: i["labels"].map { |l| l["name"] } }
    end
    range_str = "#{batch.first["number"]}..#{batch.last["number"]}"
    print "  Batch #{idx + 1}/#{batches.size} (##{range_str})... "
    $stdout.flush

    begin
      result = agent.invoke(payload.to_json)
      raw    = result[:output].to_s.strip
                              .gsub(/\A```(?:json)?\n?/, "")
                              .gsub(/\n?```\z/, "")
                              .strip
      parsed = JSON.parse(raw)
      parsed["results"].each do |r|
        pairs = Array(r["pairs"]).filter_map do |p|
          t = p["type"]
          c = p["component"]
          [t, c] if ISSUE_TYPES.key?(t) && COMPONENTS.key?(c)
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
  puts "  Parse/error count: #{parse_error_count}" if parse_error_count > 0
  puts
end

# ---------------------------------------------------------------------------
# Build aggregations
# ---------------------------------------------------------------------------
FALLBACK_PAIR = [["(unclassified)", "(unclassified)"]].freeze

# 1D type totals — unique issues that have at least one pair with this type
by_type = Hash.new { |h, k| h[k] = [] }
issues.each do |i|
  (issue_pairs[i["number"]] || FALLBACK_PAIR).map(&:first).uniq.each { |t| by_type[t] << i }
end

# 1D component totals — unique issues that touch this component (via any pair)
by_comp = Hash.new { |h, k| h[k] = [] }
issues.each do |i|
  (issue_pairs[i["number"]] || FALLBACK_PAIR).map(&:last).uniq.each { |c| by_comp[c] << i }
end

# 2D histogram: hist[type][comp] = count of meaningful (type, component) pairs
# NOT a cross-product — each pair was identified by the LLM as a distinct
# semantic annotation (one kind-of-work applied to one specific component).
hist = Hash.new { |h, k| h[k] = Hash.new(0) }
issues.each do |i|
  (issue_pairs[i["number"]] || FALLBACK_PAIR).each { |t, c| hist[t][c] += 1 }
end

# ---------------------------------------------------------------------------
# Write CSV: one row per (issue, type, component) triple
# ---------------------------------------------------------------------------
begin
  CSV.open(CSV_OUT, "w") do |csv|
    csv << %w[number state title type component]
    issues.each do |i|
      (issue_pairs[i["number"]] || FALLBACK_PAIR).each do |t, c|
        csv << [i["number"], i["state"], i["title"], t, c]
      end
    end
  end
  puts "CSV written → #{CSV_OUT}"
rescue => e
  warn "CSV write failed: #{e.message}"
end
puts

# ---------------------------------------------------------------------------
# Display helpers
# ---------------------------------------------------------------------------
BAR_W = 20

def pbar(closed, total)
  pct = total.zero? ? 0.0 : closed.fdiv(total)
  fill = (pct * BAR_W).round
  "#{"█" * fill}#{"░" * (BAR_W - fill)} #{format("%3.0f%%", pct * 100)}"
end

SEP  = "═" * 92
THIN = "─" * 92

# ---------------------------------------------------------------------------
# SECTION 1 — 1D Type breakdown
# ---------------------------------------------------------------------------
puts SEP
puts "  phronomy Issue Analysis  |  #{REPO}  |  #{LLMConfig::MODEL}"
puts "  Axes: (1) Issue Type = WHAT  ×  (2) Architectural Component = WHERE"
puts SEP
puts
puts "  SECTION 1 — Issue Type Breakdown  (Axis 1: WHAT kind of issue?)"
puts "  " + THIN

valid_types = TYPE_NAMES.select { |t| by_type.key?(t) }
valid_types.each do |t|
  list   = by_type[t]
  total  = list.size
  closed = list.count { |i| i["state"] == "CLOSED" }
  open   = total - closed
  puts format("  %-38s %3d  open:%-2d  %s", t, total, open, pbar(closed, total))
end

error_types = ["(parse error)", "(error)", "(unrecognized)", "(unclassified)"]
error_types.each do |t|
  next unless by_type.key?(t)
  list = by_type[t]
  puts format("  %-38s %3d  open:%-2d  (excluded from histogram)", t, list.size,
              list.count { |i| i["state"] == "OPEN" })
end

puts
puts format("  %-38s %3d  open:%-2d  %s",
            "TOTAL (unique issues)", issues.size, open_total,
            pbar(closed_total, issues.size))

# ---------------------------------------------------------------------------
# SECTION 2 — 1D Component breakdown
# ---------------------------------------------------------------------------
puts
puts "  SECTION 2 — Architectural Component Breakdown  (Axis 2: WHERE?)"
puts "  " + THIN
puts

valid_comps = COMP_NAMES.select { |c| by_comp.key?(c) }
valid_comps.each do |c|
  list   = by_comp[c]
  total  = list.size
  closed = list.count { |i| i["state"] == "CLOSED" }
  open   = total - closed
  puts format("  %-38s %3d  open:%-2d  %s", c, total, open, pbar(closed, total))
end

# ---------------------------------------------------------------------------
# SECTION 3 — 2D Histogram
# ---------------------------------------------------------------------------
puts
puts "  SECTION 3 — 2D Histogram: Issue Type × Architectural Component"
puts "  (cell = count of meaningful (type, component) pairs — NOT a cross-product)"
puts "  (each pair was identified by LLM as one distinct aspect of the issue)"
puts "  Section 1 & 2 counts = unique issues; Section 3 counts = semantic pairs"
puts "  " + THIN
puts

# Legend
puts "  Component abbreviations:"
COMP_NAMES.each_slice(2) do |pair|
  puts "    " + pair.map { |c| format("%-3s = %-33s", COMP_ABBR[c], c) }.join("  ")
end
puts

# Column header row
# Row label: 12 chars, each comp cell: 4 chars right-aligned
col_header = format("  %-12s", "") +
             COMP_NAMES.map { |c| format(" %3s", COMP_ABBR[c]) }.join +
             format("  %5s", "Total")
puts col_header
puts "  " + "─" * (col_header.length - 2)

# Data rows — skip types with zero row total (parse errors etc.)
row_totals = TYPE_NAMES.map do |t|
  [t, COMP_NAMES.sum { |c| hist[t][c] }]
end

row_totals.each do |t, row_total|
  next if row_total.zero?
  cells = COMP_NAMES.map { |c| format(" %3d", hist[t][c]) }.join
  abbr  = (TYPE_ABBR[t] || t[0, 11]).strip
  puts format("  %-12s", abbr) + cells + format("  %5d", row_total)
end

# Column totals
col_sums = COMP_NAMES.map { |c| TYPE_NAMES.sum { |t| hist[t][c] } }
puts "  " + "─" * (col_header.length - 2)
puts format("  %-12s", "Total") +
     col_sums.map { |s| format(" %3d", s) }.join +
     format("  %5d", col_sums.sum)
puts

# ---------------------------------------------------------------------------
# SECTION 4 — Open Issues
# ---------------------------------------------------------------------------
open_issues = issues.select { |i| i["state"] == "OPEN" }
if open_issues.any?
  puts "  SECTION 4 — Open Issues (#{open_issues.size})"
  puts "  " + THIN
  puts
  open_issues.sort_by { |i| i["number"] }.each do |issue|
    labels = issue["labels"].map { |l| l["name"] }.join(", ")
    pairs  = issue_pairs[issue["number"]] || []
    puts "  ##{issue["number"]}  #{issue["title"]}"
    puts "    Labels: #{labels.empty? ? "(none)" : labels}"
    pairs.each { |t, c| puts "    (#{t})  →  #{c}" }
    puts
  end
end

# ---------------------------------------------------------------------------
# SECTION 5 — Volume by period
# ---------------------------------------------------------------------------
puts "  SECTION 5 — Issue Volume by Period"
puts "  " + THIN
[
  ["#2-50    Initial features + first bugs",    2..50],
  ["#51-100  Code quality + docs round 1",      51..100],
  ["#101-150 Runtime / Workflow / docs",        101..150],
  ["#151-200 Deep docs audit",                  151..200],
  ["#201-260 Concurrency arch P0 planning",     201..260],
  ["#261-320 Cooperative arch implementation",  261..320],
  ["#321-383 ADR-010 cleanup / lint / CI",      321..383],
].each do |label, range|
  grp = issues.select { |i| range.cover?(i["number"]) }
  next if grp.empty?
  o = grp.count { |i| i["state"] == "OPEN" }
  c = grp.count { |i| i["state"] == "CLOSED" }
  puts format("  %-46s %3d issues  %s", label, grp.size, pbar(c, grp.size))
end
puts SEP
