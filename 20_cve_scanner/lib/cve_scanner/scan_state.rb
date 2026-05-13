# frozen_string_literal: true

# State definition for the CVE scanner pipeline.
class CveScanner::ScanState
  include Phronomy::WorkflowContext

  # ── Input ────────────────────────────────────────────────────────────────
  field :cve_ids,                 type: :replace, default: -> { [] }
  # e.g. ["CVE-2024-1234", "CVE-2023-52160"]

  # ── OS detection ─────────────────────────────────────────────────────────
  field :os_version,              type: :replace, default: nil
  field :kernel_version,          type: :replace, default: nil

  # ── CVE data ─────────────────────────────────────────────────────────────
  field :cve_infos,               type: :replace, default: -> { {} }
  # { "CVE-..." => { priority:, description:, packages: {...} } }

  # ── Check loop ───────────────────────────────────────────────────────────
  field :proposed_checks,         type: :replace, default: -> { [] }
  field :approved_checks,         type: :replace, default: -> { [] }
  field :check_history,           type: :append,  default: -> { [] }
  # accumulates { cmd:, output: } hashes across ALL rounds
  field :check_iteration,         type: :replace, default: 0
  field :check_decision,          type: :replace, default: nil
  # "need_more" | "done"

  # ── Vulnerability result ──────────────────────────────────────────────────
  field :vulnerability_status,    type: :replace, default: -> { {} }
  # { "CVE-..." => "vulnerable" | "not_vulnerable" | "unknown" }
  field :vulnerability_reasoning, type: :replace, default: -> { {} }
  # { "CVE-..." => "explanation string from analyst" }

  # ── Remediation loop ─────────────────────────────────────────────────────
  field :proposed_remediations,   type: :replace, default: -> { [] }
  field :approved_remediations,   type: :replace, default: -> { [] }
  field :remediation_history,     type: :append,  default: -> { [] }
  field :remediation_iteration,   type: :replace, default: 0
  field :remediation_decision,    type: :replace, default: nil
  # "need_more" | "complete"

  # ── UI log ────────────────────────────────────────────────────────────────
  field :messages,                type: :append,  default: -> { [] }

  # ── User input ────────────────────────────────────────────────────────────
  # Notes typed by the user at each approval step; appended to LLM context.
  field :user_notes,              type: :append,  default: -> { [] }

  # ── Post-report follow-up loop ────────────────────────────────────────────
  # The user's latest question/request after the initial report is generated.
  # Cleared after each handled turn so the next interrupt fires correctly.
  field :followup_request,        type: :replace, default: nil
  # Routing decision from FollowupAgent: "answered" | "reinvestigate" | "done"
  field :followup_decision,       type: :replace, default: nil
  # Accumulated Q&A pairs for context in subsequent turns.
  field :followup_history,        type: :append,  default: -> { [] }
end
