# frozen_string_literal: true

# Agent for post-scan Q&A. Receives full scan context plus the operator's
# question and returns a plain-text answer.
class CveScanner::ChatAgent < Phronomy::Agent::Base
  model    LLMConfig::MODEL
  provider LLMConfig::PROVIDER

  instructions <<~INST
    You are a Linux security analyst assistant.

    You have just completed a CVE vulnerability scan. You will receive:
      - The scan results (vulnerability status and assessment per CVE)
      - The check commands that were executed and their outputs
      - Any remediation commands that were executed
      - A question from the operator

    Answer the operator's question directly and concisely based on the scan
    results. Focus on practical security advice. Do not reproduce large blocks
    of raw output unless specifically asked.
  INST
end
