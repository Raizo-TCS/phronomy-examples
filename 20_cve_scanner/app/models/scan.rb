# frozen_string_literal: true

# Scan model persists a scan session.
# state_json stores the serialized ScanState between interrupts.
# status: "pending" | "running" | "awaiting_check" | "awaiting_remediation" | "awaiting_followup" | "done" | "error"
class Scan < ApplicationRecord
  serialize :cve_ids,     coder: JSON
  serialize :state_json,  coder: JSON
  serialize :result_json, coder: JSON

  validates :status, inclusion: {
    in: %w[pending running awaiting_check awaiting_remediation awaiting_followup done error]
  }

  def cve_ids_list
    Array(cve_ids)
  end
end
