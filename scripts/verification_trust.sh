#!/usr/bin/env bash

# Sourced by verify_examples.sh. The live suite inherits the caller's provider
# configuration in a new process, outside the offline RSpec environment.
verify_live_trust_acceptance() {
  header "Trust pipeline live acceptance [6 cases, including approval yes/no/cancel]"
  if ! $WITH_LLM; then
    skip "all 6 live trust acceptance cases not run (--syntax-only)"
    return
  fi

  local reports status=0
  mkdir -p "$BASE_DIR/tmp"
  reports=$(mktemp -d "$BASE_DIR/tmp/trust-live.XXXXXX")
  (
    cd "$BASE_DIR" &&
      PHRONOMY_TRUST_REPORT_DIR="$reports" bundle exec rspec integration/trust_pipeline_spec.rb \
        --no-fail-fast --format documentation
  ) || status=$?

  if [[ $status -eq 0 ]] && (cd "$BASE_DIR" && bundle exec ruby -rjson -e '
    expected = %w[invoice accepted iteration_limit approval-yes approval-no approval-cancel]
    cases = JSON.parse(File.read(ARGV.fetch(0))).fetch("cases")
    abort "Incomplete trust acceptance coverage" unless cases.keys.sort == expected.sort &&
      cases.values.all? { |item| item["status"] == "passed" && item["exit_code"] == 0 }
  ' "$reports/summary.json"); then
    pass "all 6 live trust acceptance cases passed (reports: $reports)"
  else
    fail "live trust acceptance failed, blocked or incomplete (reports: $reports)"
  fi
}
