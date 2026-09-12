#!/usr/bin/env bash

# Sourced by verify_examples.sh; SERVER_PIDS contains only its own child PIDs.
verification_require_free_port() {
  bundle exec ruby -rsocket -e '
    begin
      TCPServer.open("127.0.0.1", Integer(ARGV.fetch(0))) { }
    rescue SystemCallError, ArgumentError => error
      warn "Cannot bind verification port #{ARGV[0]}: #{error.message}"
      exit 1
    end
  ' "$1"
}

verification_stop_server() {
  local target="$1" pid owned=false
  local -a remaining=()
  for pid in "${SERVER_PIDS[@]}"; do
    if [[ "$pid" == "$target" ]]; then
      owned=true
    else
      remaining+=("$pid")
    fi
  done
  if $owned && [[ "$target" =~ ^[1-9][0-9]*$ ]]; then
    kill "$target" 2>/dev/null || true
    wait "$target" 2>/dev/null || true
  fi
  SERVER_PIDS=("${remaining[@]}")
}

verification_cleanup_servers() {
  local pid
  for pid in "${SERVER_PIDS[@]}"; do
    verification_stop_server "$pid"
  done
}
