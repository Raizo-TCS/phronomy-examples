# frozen_string_literal: true

# Agent that summarizes the content of a CVE reference page from a given
# perspective and reports any further reference URLs found on the page.
#
# Called internally by CveReferenceFetcherTool. Not used directly by other nodes.
class CveScanner::CveReferenceSummarizerAgent < Phronomy::Agent::Base
  model    LLMConfig::MODEL
  provider LLMConfig::PROVIDER

  # Single-turn summarization: no tool calls needed.
  max_iterations 1

  instructions <<~INST
    You are a security documentation analyst.

    You will receive:
      - The URL of a CVE reference page
      - The main text content extracted from that page
      - A list of further reference URLs found on the page
      - A perspective to focus on when summarizing

    Your task:
      1. Write a concise summary (3–8 sentences) of the page content from the
         given perspective. Focus on facts relevant to assessing or remediating
         the CVE: affected components, severity, root cause, patch availability,
         workarounds, or exploit status — whichever is most relevant to the
         perspective requested.
         If the perspective is not explicitly specified, focus on vulnerability
         assessment: is the system vulnerable, what is the CVSS score, and what
         packages or configurations are affected.

      2. List every further reference URL that was provided to you. Do not omit
         any. If no further reference URLs were provided, write "None".

    Output format (plain text, two sections — do not add any other text):

    SUMMARY
    <your summary here>

    FURTHER REFERENCES
    <url1>
    <url2>
    ...
  INST
end
