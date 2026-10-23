#!/usr/bin/env bash

# Sourced by verify_examples.sh. Evidence belongs to verification, not core.
verify_cli_run() {
  local name="$1"
  header "$name [CLI + LLM]"
  if [[ ! -f "$BASE_DIR/$name/run.rb" ]]; then
    skip "no run.rb found"
    return
  fi

  local reports run_rc=0
  mkdir -p "${CLI_REPORT_ROOT:-$BASE_DIR/tmp}"
  reports=$(mktemp -d "${CLI_REPORT_ROOT:-$BASE_DIR/tmp}/cli-${name}.XXXXXX")
  reports=$(cd "$reports" && pwd -P)
  (umask 077; touch "$reports/stdout.log" "$reports/stderr.log" "$reports/syntax.log")
  if ! (cd "$BASE_DIR" && bundle exec ruby -c "$name/run.rb" > "$reports/syntax.log" 2>&1); then
    fail "syntax error (evidence: $reports)"
    return
  fi

  local limit=${EXAMPLE_TIMEOUTS[$name]:-240}
  local grace=${CLI_KILL_GRACE_SECONDS:-10}
  local observation=""
  local -a command=(bundle exec ruby "$name/run.rb") arguments=()
  if [[ -n "${EXAMPLE_ARGS[$name]:-}" ]]; then
    read -r -a arguments <<< "${EXAMPLE_ARGS[$name]}"
    command+=("${arguments[@]}")
  fi
  if [[ "$name" == 19_trust_pipeline ]]; then
    observation="$reports/observation.json"
    command=(bundle exec ruby "$SCRIPT_DIR/observe_trust_cli.rb" --report "$observation"
      --snapshot-interval "${CLI_SNAPSHOT_INTERVAL_SECONDS:-5}")
  fi

  # The outer guard can interrupt the SDK before its own timeout or cleanup.
  ruby -rjson -rtime -e '
    path, name, limit, grace, observation = ARGV
    record = {example: name, status: "running", started_at: Time.now.utc.iso8601(6),
      outer_limit_seconds: Float(limit), kill_grace_seconds: Float(grace),
      observation: observation.empty? ? nil : observation,
      stdout: File.join(File.dirname(path), "stdout.log"), stderr: File.join(File.dirname(path), "stderr.log")}
    File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0600) { |f| f.write(JSON.pretty_generate(record) + "\n") }
  ' "$reports/execution.json" "$name" "$limit" "$grace" "$observation"

  (cd "$BASE_DIR" && timeout --kill-after="${grace}s" "${limit}s" "${command[@]}" < /dev/null \
    > "$reports/stdout.log" 2> "$reports/stderr.log") || run_rc=$?

  ruby -rjson -rtime -e '
    path, code = ARGV
    record = JSON.parse(File.read(path))
    code = Integer(code)
    record.merge!(exit_code: code, completed_at: Time.now.utc.iso8601(6),
      status: {0 => "completed", 124 => "outer_cutoff", 137 => "killed"}.fetch(code, "failed"))
    # 137 can also be an external SIGKILL; do not invent its origin.
    File.open(path + ".tmp", "w", 0600) { |f| f.write(JSON.pretty_generate(record) + "\n") }
    File.rename(path + ".tmp", path)
  ' "$reports/execution.json" "$run_rc"

  if [[ $run_rc -eq 0 ]]; then
    pass "run OK (exit 0; evidence: $reports)"
  elif [[ $run_rc -eq 124 ]]; then
    fail "run reached outer cutoff (${limit}s; SDK timeout/cleanup not implied; evidence: $reports)"
  elif [[ $run_rc -eq 137 ]]; then
    fail "run killed (exit 137; cleanup unconfirmed; evidence: $reports)"
  else
    fail "run failed (exit $run_rc; evidence: $reports)"
  fi
}
