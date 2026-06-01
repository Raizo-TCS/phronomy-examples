#!/usr/bin/env bash
# verify_examples.sh
#
# Smoke-tests all phronomy-examples:
#   - CLI samples: actual LLM run with 240s timeout  (default)
#                  OR Ruby syntax check only           (--syntax-only)
#   - Rails apps:  db:migrate, server boot, health check, Playwright GUI smoke test
#
# Usage:
#   cd phronomy-examples
#   bash scripts/verify_examples.sh               # full run via LLM (LM Studio must be up)
#   bash scripts/verify_examples.sh --syntax-only # syntax-only, no LLM required
#
# The Rails GUI tests require the 'playwright' npm package (auto-installed into
# scripts/browser_tests/node_modules on first run) and a Chromium browser
# (installed via `npx playwright install chromium` automatically if missing).
#
# Rails server is started in development mode on dedicated ports to avoid
# conflicts with any existing service.

set -euo pipefail

# ── Flag parsing ──────────────────────────────────────────────────────────────
WITH_LLM=true
for arg in "$@"; do
  [[ "$arg" == "--syntax-only" ]] && WITH_LLM=false
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
BROWSER_TESTS_DIR="$SCRIPT_DIR/browser_tests"

export PATH="$HOME/.local/share/gem/ruby/3.2.0/bin:$PATH"

# ── Terminal colours ─────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; BOLD='\033[1m'; NC='\033[0m'

# ── LM Studio / LLM configuration ────────────────────────────────────────────
# These variables are inherited from the caller's environment if already set.
# Defaults point to a local LM Studio instance used for CI/verification.
export PHRONOMY_MODEL="${PHRONOMY_MODEL:-openai/gpt-oss-20b}"
export PHRONOMY_BASE_URL="${PHRONOMY_BASE_URL:-http://192.168.122.1:1234/v1}"
export PHRONOMY_API_KEY="${PHRONOMY_API_KEY:-lm-studio}"
export PHRONOMY_PROVIDER="${PHRONOMY_PROVIDER:-openai}"

# ── Per-example LLM timeout overrides (seconds; default: 240) ────────────────
# Add entries here for examples that require more than 240 seconds to run.
declare -A EXAMPLE_TIMEOUTS
EXAMPLE_TIMEOUTS["10_context_management"]=480   # 9 LLM calls ~270s typical
EXAMPLE_TIMEOUTS["27_issue_analyzer"]=900       # 25 batches × up to ~10s each

# ── Counters & failure list ───────────────────────────────────────────────────
PASS=0; FAIL=0; SKIP=0
FAILURES=()
SERVER_PIDS=()

# ── Helpers ───────────────────────────────────────────────────────────────────
pass()  { echo -e "  ${GREEN}[PASS]${NC} $1"; PASS=$((PASS + 1)); }
fail()  { echo -e "  ${RED}[FAIL]${NC} $1"; FAIL=$((FAIL + 1)); FAILURES+=("$1"); }
skip()  { echo -e "  ${YELLOW}[SKIP]${NC} $1"; SKIP=$((SKIP + 1)); }
header(){ echo -e "\n${BOLD}=== $1 ===${NC}"; }

# Kill any process listening on a given port (best-effort, no error if empty).
free_port() {
  local port="$1"
  lsof -ti :"$port" 2>/dev/null | xargs -r kill -9 2>/dev/null || true
}

# Cleanup all background Rails servers on exit.
cleanup() {
  for pid in "${SERVER_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ── CLI example verification ──────────────────────────────────────────────────
# Checks: Ruby syntax (ruby -c).
# LLM is not called — syntax is the only deterministic check without a server.
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

# ── CLI example verification with LLM ────────────────────────────────────────
# Checks: Ruby syntax, then actual run via LLM with a 240-second timeout.
verify_cli_run() {
  local name="$1"
  local dir="$BASE_DIR/$name"
  header "$name [CLI + LLM]"

  if [[ ! -f "$dir/run.rb" ]]; then
    skip "no run.rb found"
    return
  fi

  # Syntax check first.
  if ! (cd "$BASE_DIR" && bundle exec ruby -c "$name/run.rb" > /dev/null 2>&1); then
    local err
    err=$(cd "$BASE_DIR" && bundle exec ruby -c "$name/run.rb" 2>&1 || true)
    fail "syntax error: $err"
    return
  fi

  # Actual run via LLM (240-second default timeout, overridable per example).
  # stdin is redirected from /dev/null so interactive prompts receive EOF and
  # the example can exit gracefully without blocking.
  local llm_timeout=${EXAMPLE_TIMEOUTS[$name]:-240}
  local run_out run_rc=0
  run_out=$(cd "$BASE_DIR" && timeout $llm_timeout bundle exec ruby "$name/run.rb" < /dev/null 2>&1) || run_rc=$?
  if [[ $run_rc -eq 0 ]]; then
    pass "run OK (exit 0)"
  elif [[ $run_rc -eq 124 ]]; then
    fail "run timed out (>${llm_timeout}s)"
  else
    fail "run failed (exit $run_rc): ${run_out: -300}"
  fi
}

# ── Rails app verification ────────────────────────────────────────────────────
# Checks: db:migrate, server boot, GET /up → 200, Playwright page load & UI.
verify_rails() {
  local name="$1"
  local port="$2"
  local extra_env="${3:-}"   # optional extra env vars (e.g. "CVE_SCANNER_MOCK_LLM=1")
  local dir="$BASE_DIR/$name"
  header "$name [Rails, port $port]"

  if [[ ! -d "$dir" ]]; then
    skip "directory not found: $dir"
    return
  fi

  # 1. DB migrate ─────────────────────────────────────────────────────────────
  local migrate_out
  if migrate_out=$(cd "$dir" && RAILS_ENV=development bundle exec rails db:create db:migrate 2>&1); then
    pass "db:create db:migrate"
  else
    fail "db:migrate: ${migrate_out: -300}"
    return
  fi

  # 2. Start server ───────────────────────────────────────────────────────────
  free_port "$port"
  local log_file
  log_file="$(mktemp /tmp/rails-${name}-XXXXXX.log)"

  (cd "$dir" && env PORT=$port RAILS_ENV=development $extra_env bundle exec rails server \
      >> "$log_file" 2>&1) &
  local server_pid=$!
  SERVER_PIDS+=("$server_pid")

  # Wait up to 40 s for the health endpoint.
  local up=false
  for i in $(seq 1 40); do
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

  # 3. Health check ───────────────────────────────────────────────────────────
  local http_code
  http_code=$(curl -so /dev/null -w "%{http_code}" "http://localhost:$port/up")
  if [[ "$http_code" == "200" ]]; then
    pass "GET /up → 200"
  else
    fail "GET /up → $http_code"
  fi

  # 4. Playwright GUI smoke test ───────────────────────────────────────────────
  run_playwright_test "$name" "$port" "$extra_env"

  # 5. Stop server ─────────────────────────────────────────────────────────────
  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
  SERVER_PIDS=("${SERVER_PIDS[@]/$server_pid}")
  pass "server stopped"
}

# ── Playwright runner ─────────────────────────────────────────────────────────
run_playwright_test() {
  local name="$1"
  local port="$2"
  local extra_env="${3:-}"

  # Ensure npm dependencies are installed.
  if [[ ! -d "$BROWSER_TESTS_DIR/node_modules/playwright" ]]; then
    echo "  Installing Playwright npm package…"
    if ! (cd "$BROWSER_TESTS_DIR" && npm install --silent 2>&1); then
      skip "npm install failed — Playwright tests skipped"
      return
    fi
  fi

  # Ensure Chromium browser binary is present.
  if ! (cd "$BROWSER_TESTS_DIR" && node -e "require('playwright')" > /dev/null 2>&1); then
    skip "playwright module not loadable — GUI tests skipped"
    return
  fi

  # Verify the chromium headless shell binary actually exists; install if missing.
  local chrome_exe
  chrome_exe=$(cd "$BROWSER_TESTS_DIR" && \
    node -e "const {chromium}=require('playwright'); console.log(chromium.executablePath())" 2>/dev/null || true)
  if [[ -z "$chrome_exe" || ! -f "$chrome_exe" ]]; then
    echo "  Installing Playwright Chromium (headless shell)…"
    (cd "$BROWSER_TESTS_DIR" && node_modules/.bin/playwright install chromium 2>&1 | tail -5) || true
  fi

  # Run the smoke test.
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

# ── CLI examples ─────────────────────────────────────────────────────────────
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
  16_before_completion_hook
  17_multi_agent_handoff
  19_trust_pipeline
  21_team_coordinator
  22_shared_state
  23_bounded_parallel
  24_vector_store_dimension
  25_event_loop
  26_agent_event_loop
  27_issue_analyzer
)

echo -e "${BOLD}======================================================${NC}"
echo -e "${BOLD}  phronomy-examples verification${NC}"
echo -e "${BOLD}======================================================${NC}"

for example in "${CLI_EXAMPLES[@]}"; do
  if $WITH_LLM; then
    verify_cli_run "$example"
  else
    verify_cli "$example"
  fi
done

# ── Rails apps (each on a dedicated port) ────────────────────────────────────
verify_rails "09_rails_chat"        3009
verify_rails "15_rails_secure_chat" 3015
verify_rails "18_rails_agent_job"   3018
verify_rails "20_cve_scanner"       3020 "CVE_SCANNER_MOCK_LLM=1"

# ── Summary ───────────────────────────────────────────────────────────────────
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
  echo -e "  CLI: syntax + LLM run (timeout 240s)"
else
  echo -e "  CLI: syntax-only (no LLM required)"
fi
echo -e "  Rails: db + server + health + Playwright GUI"
echo -e "======================================================${NC}"

[[ $FAIL -eq 0 ]]
