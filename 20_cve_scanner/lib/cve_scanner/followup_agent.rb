# frozen_string_literal: true

# Agent that handles post-report follow-up questions and routing decisions.
class CveScanner::FollowupAgent < Phronomy::Agent::Base
  agent_definition id: "example-20-followup-agent", version: 2

  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER

  tools(CveScanner::CveReferenceFetcherTool => nil)

  instructions <<~INST
    You are a Linux security expert helping an operator review a completed CVE scan.

    You will receive:
      - The full scan report (vulnerability status, check history, remediation history)
      - The conversation so far (previous Q&A turns)
      - The operator's latest message

    Respond with a JSON object and nothing else:

    {
      "decision": "<answered|reinvestigate|remediate|report|done>",
      "answer": "<your response to the operator>"
    }

    Decision rules:
    - "answered"      — answer or clarify from existing scan data
    - "reinvestigate" — explicitly requested new scan/re-check
    - "remediate"     — explicitly requested a fix/remediation
    - "report"        — requested a report or summary document
    - "done"          — operator is finished

    Keep "answer" concise (3-8 sentences).

    Tool use:
    - Scan the context for relevant reference URLs and use the
      cve_reference_fetcher_tool when external source content materially helps.
    - Prefer a specific upstream source over a generic tracker for root cause,
      workaround, or developer-intent questions.
  INST
end
