#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXAMPLE_DIR="$ROOT_DIR/31_postgresql_persistence"

export PHRONOMY_POSTGRES_URL="${PHRONOMY_POSTGRES_URL:-postgresql://postgres:postgres@127.0.0.1:5432/phronomy_persistence_test}"

echo "PostgreSQL Persistence verification"
echo "  database: PHRONOMY_POSTGRES_URL configured"
echo

cd "$EXAMPLE_DIR"

bundle exec ruby -e '
  require "phronomy"
  spec = Gem.loaded_specs.fetch("phronomy")
  puts "Phronomy #{Phronomy::VERSION}"
  puts spec.full_gem_path
'

echo
echo "==> Authoritative contract + PostgreSQL integration specs"
bundle exec rspec

echo
echo "==> Fresh-pool durable reload demonstration"
bundle exec ruby run.rb

echo
echo "PostgreSQL Persistence verification passed."
