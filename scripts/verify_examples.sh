#!/usr/bin/env bash
# verify_examples.sh
#
# Smoke-tests all phronomy-examples:
#   - dependency preflight: every bundle must load the same Phronomy version/path
#   - removed-API / architecture preflight
#   - active-documentation stale-API preflight
#   - CLI samples: actual LLM run with timeout (default)
#                  OR Ruby syntax check only (--syntax-only)
#   - Rails apps: db:migrate, Zeitwerk check, server boot, health check,
#                 Playwright GUI smoke test
#
# Usage:
#   cd phronomy-examples
#   bash scripts/verify_examples.sh
#   bash scripts/verify_examples.sh --syntax-only
#
# Before verification:
#   ./scripts/update_phronomy.sh

set -euo pipefail

WITH_LLM=true
for arg in "$@"; do
  [[ "$arg" == "--syntax-only" ]] && WITH_LLM=false
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
BROWSER_TESTS_DIR="$SCRIPT_DIR/browser_tests"

export PATH="$HOME/.local/share/gem/ruby/3.2.0/bin:$PATH"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; BOLD='\033[1m'; NC='\033[0m'

export PHRONOMY_MODEL="${PHRONOMY_MODEL:-openai/gpt-oss-20b}"
export PHRONOMY_BASE_URL="${PHRONOMY_BASE_URL:-http://192.168.122.1:1234/v1}"
export PHRONOMY_API_KEY="${PHRONOMY_API_KEY:-lm-studio}"
export PHRONOMY_PROVIDER="${PHRONOMY_PROVIDER:-openai}"

declare -A EXAMPLE_TIMEOUTS
EXAMPLE_TIMEOUTS["05_multi_agent"]=360
EXAMPLE_TIMEOUTS["10_context_management"]=720
EXAMPLE_TIMEOUTS["27_issue_analyzer"]=900

declare -A EXAMPLE_ARGS
EXAMPLE_ARGS["27_issue_analyzer"]="--dry-run"

PASS=0; FAIL=0; SKIP=0
FAILURES=()
SERVER_PIDS=()

pass()  { echo -e "  ${GREEN}[PASS]${NC} $1"; PASS=$((PASS + 1)); }
fail()  { echo -e "  ${RED}[FAIL]${NC} $1"; FAIL=$((FAIL + 1)); FAILURES+=("$1"); }
skip()  { echo -e "  ${YELLOW}[SKIP]${NC} $1"; SKIP=$((SKIP + 1)); }
header(){ echo -e "\n${BOLD}=== $1 ===${NC}"; }

free_port() {
  local port="$1"
  lsof -ti :"$port" 2>/dev/null | xargs -r kill -9 2>/dev/null || true
}

cleanup() {
  for pid in "${SERVER_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

verify_phronomy_dependency() {
  header "Phronomy dependency preflight"

  local gemfiles=(
    "$BASE_DIR/Gemfile"
    "$BASE_DIR/09_rails_chat/Gemfile"
    "$BASE_DIR/15_rails_secure_chat/Gemfile"
    "$BASE_DIR/18_rails_agent_job/Gemfile"
    "$BASE_DIR/20_cve_scanner/Gemfile"
  )

  local expected_version=""
  local expected_source_key=""
  local expected_local_path=""
  local gemfile bundle_dir display resolved version path source_key
  local preflight_failed=false

  if [[ -n "${PHRONOMY_PATH:-}" ]]; then
    expected_local_path="$(cd "$BASE_DIR" && cd "$PHRONOMY_PATH" && pwd -P)"
  fi

  for gemfile in "${gemfiles[@]}"; do
    bundle_dir="$(dirname "$gemfile")"
    display="${gemfile#"$BASE_DIR"/}"

    if ! resolved=$(
      cd "$bundle_dir" &&
        BUNDLE_GEMFILE="$gemfile" bundle exec ruby -e '
          require "phronomy"
          spec = Gem.loaded_specs.fetch("phronomy")
          puts "#{Phronomy::VERSION}\t#{File.realpath(spec.full_gem_path)}"
        '
    ); then
      fail "$display cannot load Phronomy; run ./scripts/update_phronomy.sh"
      preflight_failed=true
      continue
    fi

    version="${resolved%%$'\t'*}"
    path="${resolved#*$'\t'}"
    source_key="$(basename "$path")"

    echo "  $display"
    echo "    version: $version"
    echo "    path:    $path"
    echo "    source:  $source_key"

    if [[ -z "$expected_version" ]]; then
      expected_version="$version"
      expected_source_key="$source_key"
      pass "$display establishes Phronomy baseline"
    elif [[ "$version" != "$expected_version" ]]; then
      fail "$display loads Phronomy $version; expected $expected_version"
      preflight_failed=true
    else
      pass "$display matches Phronomy $expected_version"
    fi

    if [[ -n "$expected_source_key" && "$source_key" != "$expected_source_key" ]]; then
      fail "$display loads Phronomy source $source_key; baseline is $expected_source_key"
      preflight_failed=true
    elif [[ "$source_key" == "$expected_source_key" ]]; then
      pass "$display matches the baseline Phronomy source revision/build"
    fi

    if [[ -n "$expected_local_path" && "$path" != "$expected_local_path" ]]; then
      fail "$display loads Phronomy from $path; expected local checkout $expected_local_path"
      preflight_failed=true
    fi

    if [[ -n "$expected_local_path" && "$path" == "$expected_local_path" ]]; then
      echo "    local checkout: OK"
    fi
  done

  if $preflight_failed; then
    echo
    echo -e "${RED}Dependency preflight failed.${NC}"
    echo "Run ./scripts/update_phronomy.sh and verify again."
    return 1
  fi

  echo
  echo "All bundles load the same Phronomy version and source revision/build."
}

# High-signal migration mistakes that Ruby syntax checking cannot detect.
# Executable Ruby is checked; documentation may mention historical names while
# explaining migrations.
verify_removed_api_contract() {
  header "Current Phronomy source API preflight"

  local failed=false
  local matches i
  local -a patterns=(
    'Phronomy::Guardrail::'
    'Phronomy::Agent::Context::Knowledge::StaticKnowledge'
    '^[[:space:]]*static_knowledge([[:space:](]|$)'
    'Phronomy::Rails::AgentJob'
    'send\(:prepare_tool_class'
    '^[[:space:]]*tools[[:space:]]+[A-Z][A-Za-z0-9_:]*(,[[:space:]]*[A-Z][A-Za-z0-9_:]*)*([[:space:]]*(#.*)?)$'
    '\.tools\([[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\)'
    'Phronomy::Runtime\.instance\.spawn'
    'Phronomy::Runtime\.instance\.yield([[:space:](]|$)'
    'Runtime#spawn'
    'Runtime#yield'
    'runtime_backend'
    'Phronomy::Eval::'
    '(^|[^A-Za-z0-9_:])TaskGroup([^A-Za-z0-9_]|$)'
    'ThreadBackend'
    'FiberBackend'
    'ImmediateBackend'
    'DeterministicScheduler'
    'ThreadScheduler'
    'FakeScheduler'
    'Phronomy::ActiveRecord::ActsAs'
    'acts_as_phronomy_checkpoint'
    'Phronomy::StateStore'
    'StateStore::InMemory'
    'Phronomy::Runtime\.instance\.blocking_io'
    'Runtime#blocking_io'
    'BlockingAdapterPool'
    '^[[:space:]]*[A-Z][A-Za-z0-9_:]*\.approve(_async)?[[:space:]]*\('
  )
  local -a labels=(
    'removed Guardrail namespace'
    'removed StaticKnowledge constant'
    'removed static_knowledge DSL'
    'removed Rails AgentJob adapter'
    'private prepare_tool_class usage'
    'pre-0.17 tools splat DSL'
    'pre-0.17 dynamic tools single-argument registration'
    'removed Runtime.instance.spawn API'
    'removed Runtime.instance.yield API'
    'removed Runtime#spawn source guidance'
    'removed Runtime#yield source guidance'
    'removed runtime_backend configuration'
    'product-facing Phronomy::Eval namespace'
    'removed TaskGroup runtime primitive'
    'removed ThreadBackend runtime primitive'
    'removed FiberBackend runtime primitive'
    'removed ImmediateBackend runtime primitive'
    'removed DeterministicScheduler runtime primitive'
    'removed ThreadScheduler runtime primitive'
    'removed FakeScheduler runtime primitive'
    'removed Phronomy ActiveRecord integration'
    'removed acts_as_phronomy_checkpoint DSL'
    'removed Phronomy::StateStore namespace'
    'removed StateStore::InMemory backend'
    'removed Runtime.instance.blocking_io API'
    'removed Runtime#blocking_io source guidance'
    'removed BlockingAdapterPool name'
    'removed class-level Agent approval routing'
  )

  for i in "${!patterns[@]}"; do
    matches=$(grep -RInE --include='*.rb' --exclude-dir=vendor "${patterns[$i]}" "$BASE_DIR" 2>/dev/null || true)
    if [[ -n "$matches" ]]; then
      fail "${labels[$i]}"
      echo "$matches" | sed 's/^/    /'
      failed=true
    else
      pass "${labels[$i]} not found"
    fi
  done

  ! $failed
}

verify_active_docs_contract() {
  header "Current Phronomy documentation preflight"

  local failed=false
  local matches i
  local -a patterns=(
    'BlockingAdapterPool'
    'Runtime#blocking_io'
    'Workflow / StateStore'
    'Phronomy 0\.1[67]'
  )
  local -a labels=(
    'removed BlockingAdapterPool name in active Markdown'
    'removed Runtime#blocking_io API in active Markdown'
    'removed Workflow / StateStore architecture category'
    'stale Phronomy 0.16/0.17 version guidance'
  )

  for i in "${!patterns[@]}"; do
    matches=$(grep -RInE --include='*.md' --exclude-dir=vendor "${patterns[$i]}" "$BASE_DIR" 2>/dev/null || true)
    if [[ -n "$matches" ]]; then
      fail "${labels[$i]}"
      echo "$matches" | sed 's/^/    /'
      failed=true
    else
      pass "${labels[$i]} not found"
    fi
  done

  ! $failed
}


verify_standalone_smoke_tests() {
  header "Standalone smoke-test syntax"

  local file="$BASE_DIR/test_approval_lmstudio.rb"
  if (cd "$BASE_DIR" && bundle exec ruby -c "$file" > /dev/null 2>&1); then
    pass "test_approval_lmstudio.rb syntax OK"
  else
    local err
    err=$(cd "$BASE_DIR" && bundle exec ruby -c "$file" 2>&1 || true)
    fail "test_approval_lmstudio.rb syntax error: $err"
    return 1
  fi
}

# Examples 14 and 20 are specifically intended to demonstrate Phronomy's
# EventLoop/FSMSession control plane. Raw application Threads in these paths are
# therefore an architecture regression. Example 13 may still use a background
# Thread for its demo HTTP server; that is infrastructure, not Phronomy control.
verify_event_loop_example_contract() {
  header "EventLoop example architecture preflight"

  local matches
  matches=$(
    grep -RInE --include='*.rb' 'Thread\.(new|start)' \
      "$BASE_DIR/14_code_review" \
      "$BASE_DIR/20_cve_scanner/lib/cve_scanner/scan_graph.rb" \
      2>/dev/null || true
  )

  if [[ -n "$matches" ]]; then
    fail "raw application Threads found in EventLoop-oriented examples"
    echo "$matches" | sed 's/^/    /'
    return 1
  fi

  pass "no raw application Threads in examples 14/20 orchestration"
}

verify_cli() {
  local name="$1"
  local dir="$BASE_DIR/$name"
  header "$name [CLI]"

  if [[ ! -f "$dir/run.rb" ]]; then
    skip "no run.rb found"
    return
  fi

  if (cd "$BASE_DIR" && bundle exec ruby -c "$name/run.rb" > /dev/null 2>&1); then
    pass "syntax OK"
  else
    local err
    err=$(cd "$BASE_DIR" && bundle exec ruby -c "$name/run.rb" 2>&1 || true)
    fail "syntax error: $err"
  fi
}

verify_cli_run() {
  local name="$1"
  local dir="$BASE_DIR/$name"
  header "$name [CLI + LLM]"

  if [[ ! -f "$dir/run.rb" ]]; then
    skip "no run.rb found"
    return
  fi

  if ! (cd "$BASE_DIR" && bundle exec ruby -c "$name/run.rb" > /dev/null 2>&1); then
    local err
    err=$(cd "$BASE_DIR" && bundle exec ruby -c "$name/run.rb" 2>&1 || true)
    fail "syntax error: $err"
    return
  fi

  local llm_timeout=${EXAMPLE_TIMEOUTS[$name]:-240}
  local extra_args=${EXAMPLE_ARGS[$name]:-}
  local run_out run_rc=0
  run_out=$(cd "$BASE_DIR" && timeout "$llm_timeout" bundle exec ruby "$name/run.rb" $extra_args < /dev/null 2>&1) || run_rc=$?
  if [[ $run_rc -eq 0 ]]; then
    pass "run OK (exit 0)"
  elif [[ $run_rc -eq 124 ]]; then
    fail "run timed out (>${llm_timeout}s)"
  else
    fail "run failed (exit $run_rc): ${run_out: -300}"
  fi
}

verify_rails() {
  local name="$1"
  local port="$2"
  local extra_env="${3:-}"
  local dir="$BASE_DIR/$name"
  header "$name [Rails, port $port]"

  if [[ ! -d "$dir" ]]; then
    skip "directory not found: $dir"
    return
  fi

  local migrate_out
  if migrate_out=$(cd "$dir" && RAILS_ENV=development bundle exec rails db:create db:migrate 2>&1); then
    pass "db:create db:migrate"
  else
    fail "db:migrate: ${migrate_out: -300}"
    return
  fi

  local zeitwerk_out
  if zeitwerk_out=$(cd "$dir" && RAILS_ENV=development bundle exec rails zeitwerk:check 2>&1); then
    pass "zeitwerk:check"
  else
    fail "zeitwerk:check: ${zeitwerk_out: -300}"
    return
  fi

  free_port "$port"
  local log_file
  log_file="$(mktemp "${TMPDIR:-/tmp}/rails-${name}-XXXXXX.log")"

  (cd "$dir" && env PORT="$port" RAILS_ENV=development $extra_env bundle exec rails server \
      >> "$log_file" 2>&1) &
  local server_pid=$!
  SERVER_PIDS+=("$server_pid")

  local up=false
  for _ in $(seq 1 40); do
    if curl -sf "http://localhost:$port/up" > /dev/null 2>&1; then
      up=true
      break
    fi
    sleep 1
  done

  if [[ "$up" != "true" ]]; then
    fail "server did not start within 40s (log: $log_file)"
    kill "$server_pid" 2>/dev/null || true
    return
  fi
  pass "server started (PID $server_pid)"

  local http_code
  http_code=$(curl -so /dev/null -w "%{http_code}" "http://localhost:$port/up")
  if [[ "$http_code" == "200" ]]; then
    pass "GET /up → 200"
  else
    fail "GET /up → $http_code"
  fi

  run_playwright_test "$name" "$port" "$extra_env"

  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
  SERVER_PIDS=("${SERVER_PIDS[@]/$server_pid}")
  pass "server stopped"
}

run_playwright_test() {
  local name="$1"
  local port="$2"
  local extra_env="${3:-}"

  if [[ ! -d "$BROWSER_TESTS_DIR/node_modules/playwright" ]]; then
    echo "  Installing Playwright npm package…"
    if ! (cd "$BROWSER_TESTS_DIR" && npm install --silent 2>&1); then
      skip "npm install failed — Playwright tests skipped"
      return
    fi
  fi

  if ! (cd "$BROWSER_TESTS_DIR" && node -e "require('playwright')" > /dev/null 2>&1); then
    skip "playwright module not loadable — GUI tests skipped"
    return
  fi

  local chrome_exe
  chrome_exe=$(cd "$BROWSER_TESTS_DIR" && \
    node -e "const {chromium}=require('playwright'); console.log(chromium.executablePath())" 2>/dev/null || true)
  if [[ -z "$chrome_exe" || ! -f "$chrome_exe" ]]; then
    echo "  Installing Playwright Chromium (headless shell)…"
    (cd "$BROWSER_TESTS_DIR" && node_modules/.bin/playwright install chromium 2>&1 | tail -5) || true
  fi

  local pw_out
  if pw_out=$(cd "$BROWSER_TESTS_DIR" && env APP_NAME="$name" VERIFY_PORT="$port" $extra_env \
              node smoke_test.js 2>&1); then
    echo "$pw_out" | sed 's/^/  /'
    pass "Playwright smoke test"
  else
    echo "$pw_out" | sed 's/^/  /'
    fail "Playwright smoke test"
  fi
}

CLI_EXAMPLES=(
  01_basic_chain
  02_react_agent
  03_state_graph
  04_interrupt_resume
  05_multi_agent
  06_guardrails
  07_tracing
  08_mcp_tool
  10_context_management
  11_agent_streaming
  12_prompt_template
  13_mcp_http_tool
  14_code_review
  16_before_llm_input_hook
  17_multi_agent_handoff
  19_trust_pipeline
  21_team_coordinator
  22_shared_state
  23_bounded_parallel
  24_vector_store_dimension
  25_event_loop
  26_agent_event_loop
  27_issue_analyzer
  28_filter
  29_unified_persistence
)

echo -e "${BOLD}======================================================${NC}"
echo -e "${BOLD}  phronomy-examples verification${NC}"
echo -e "${BOLD}======================================================${NC}"

if ! verify_phronomy_dependency; then
  exit 1
fi

if ! verify_removed_api_contract; then
  exit 1
fi

if ! verify_active_docs_contract; then
  exit 1
fi

if ! verify_event_loop_example_contract; then
  exit 1
fi

if ! verify_standalone_smoke_tests; then
  exit 1
fi

for example in "${CLI_EXAMPLES[@]}"; do
  if $WITH_LLM; then
    verify_cli_run "$example"
  else
    verify_cli "$example"
  fi
done

verify_rails "09_rails_chat"        3009
verify_rails "15_rails_secure_chat" 3015
verify_rails "18_rails_agent_job"   3018
verify_rails "20_cve_scanner"       3020 "CVE_SCANNER_MOCK_LLM=1"

echo ""
echo -e "${BOLD}======================================================"
echo -e "  RESULTS"
echo -e "======================================================${NC}"
echo -e "  ${GREEN}PASS${NC}: $PASS"
echo -e "  ${RED}FAIL${NC}: $FAIL"
echo -e "  ${YELLOW}SKIP${NC}: $SKIP"

if [[ ${#FAILURES[@]} -gt 0 ]]; then
  echo ""
  echo -e "  ${RED}Failed checks:${NC}"
  for f in "${FAILURES[@]}"; do
    echo "    - $f"
  done
fi

echo -e "${BOLD}======================================================"
if $WITH_LLM; then
  echo -e "  CLI: syntax + LLM run (default timeout 240s)"
else
  echo -e "  CLI: syntax-only (no LLM required)"
fi
echo -e "  Rails: db + Zeitwerk + server + health + Playwright GUI"
echo -e "======================================================${NC}"

[[ $FAIL -eq 0 ]]
