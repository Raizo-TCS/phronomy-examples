# frozen_string_literal: true

require "json"
require "stringio"

# Predetermined answers belong to the test harness, never the interactive demo.
module TrustApprovalAcceptance
  MAX_APPROVALS = 2 # Matches approval_demo.rb's bounded draft iterations.

  def self.input(answer)
    StringIO.new("#{answer}\n" * ((answer == "yes") ? MAX_APPROVALS : 1))
  end

  def self.yes?(records, result)
    return false unless result && result["failure"].nil? &&
      %w[accepted iteration_limit].include?(result["termination_reason"])

    data = JSON.parse(JSON.generate(records))
    approvals = data.fetch("approvals")
    count = approvals.length
    return false unless (1..MAX_APPROVALS).cover?(count) && result["iterations"] == count

    values = approvals.map { |entry| entry.fetch("value") }
    requests = values.map { |value| value.fetch("request") }
    return false unless values.all? { |value| value["phase"] == "draft" } &&
      values.map { |value| value["invocation_id"] }.uniq.length == 1
    return false unless requests.all? { |request|
      request["items"].length == 1 && request["items"].first["tool_name"] == "approved_policy_lookup"
    }

    ids = requests.map { |request| request.fetch("id") }
    return false unless ids.all? { |id| id.is_a?(String) && !id.empty? } && ids.uniq.length == count
    return false unless requests.map { |request| request["execution_id"] }.uniq.length == count
    decisions = data.fetch("decisions")
    return false unless decisions.map { |decision| decision["request_id"] } == ids &&
      decisions.all? { |decision| decision["approved"] == true }

    expected = requests.map { |request|
      item = request.fetch("items").first
      [request.fetch("execution_id"), item.fetch("tool_invocation_id"), item.fetch("tool_call_id")]
    }
    effects = data.fetch("tool_effects").map { |effect|
      [effect["execution_id"], effect["tool_invocation_id"], effect["tool_call_id"]]
    }
    expected.uniq.length == count && effects == expected && data.fetch("tool_executions") == count
  end
end
