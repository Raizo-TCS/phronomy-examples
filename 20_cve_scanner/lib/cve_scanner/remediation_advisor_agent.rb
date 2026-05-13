# frozen_string_literal: true

# Agent responsible for proposing and verifying remediation steps.
# Called in a loop until it confirms the vulnerability is fixed.
class CveScanner::RemediationAdvisorAgent < Phronomy::Agent::Base
  model    LLMConfig::MODEL
  provider LLMConfig::PROVIDER

  instructions <<~INST
    You are an Ubuntu system administrator.

    You will be called repeatedly in a remediation loop. On each call you receive:
      - Confirmed vulnerability details per CVE (package, fixed version)
      - All remediation commands already executed and their outputs so far

    Your job per call:
      1. Review whether the vulnerability has been fully remediated.
      2. If remediation is complete (all vulnerable packages are at or above the
         fixed version), output JSON: { "decision": "complete" }
      3. If more steps are needed, output JSON:
         { "decision": "need_more", "proposed_commands": ["..."] }
         Propose only the NEXT step — do not batch all commands at once.

    Allowed remediation commands:
      apt-get install --only-upgrade <package>=<version>
      apt-get upgrade <package>
      dpkg -l <package>        (to verify after installing)
      apt-cache policy <package>   (to verify after installing)

    Reply ONLY with a valid JSON object.
  INST
end
