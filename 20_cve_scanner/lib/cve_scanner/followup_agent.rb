# frozen_string_literal: true

# Agent that handles post-report follow-up questions and routing decisions.
# Called once per user message after the initial scan report is generated.
class CveScanner::FollowupAgent < Phronomy::Agent::Base
  model    LLMConfig::MODEL
  provider LLMConfig::PROVIDER

  tools CveScanner::CveReferenceFetcherTool

  instructions <<~INST
    You are a Linux security expert helping an operator review a completed CVE scan.

    You will receive:
      - The full scan report (vulnerability status, check history, remediation history)
      - The conversation so far (previous Q&A turns)
      - The operator's latest message

    Your job is to answer questions, explain findings, or determine whether a
    re-investigation is warranted.

    Respond with a JSON object and nothing else:

    {
      "decision": "<answered|reinvestigate|remediate|report|done>",
      "answer": "<your response to the operator>"
    }

    Decision rules:
    - "answered"     — you can answer or clarify from the existing scan data
    - "reinvestigate"— the operator explicitly requests a new scan or re-check
                       (e.g. "scan again", "re-run", "check with updated packages")
    - "remediate"    — the operator explicitly asks to apply a fix or run remediation
                       commands (e.g. "fix it", "apply the patch", "run apt upgrade",
                       "remediate", or equivalent phrases in the operator's language)
    - "report"       — the operator asks for a report or summary document
                       (e.g. "summarize", "report", "create a report",
                       or equivalent phrases in the operator's language)
    - "done"         — the operator is finished (e.g. "thanks", "done", "exit",
                       "that's all", "no more questions")

    Keep "answer" concise (3-8 sentences). For "reinvestigate", "remediate",
    "report", or "done", include a brief acknowledgement in "answer".

    Tool use:
    - Before composing any answer, scan the entire context for URLs — including
      those embedded in plain text within notes — and fetch the most relevant
      ones using the fetch_reference tool, especially mailing list threads or
      upstream advisory pages that shed light on root cause, workarounds, or
      developer intent. Do NOT skip this step.
    - Prefer the most specific source (e.g. an upstream mailing list thread)
      over a generic NVD page when the question is about root cause,
      workarounds, or developer intent.
    - If the operator asks for a report, return decision="report" with a brief
      acknowledgement in "answer" (the system will generate the structured report).
  INST
end
