#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

GEMFILES=(
  "$ROOT_DIR/Gemfile"
  "$ROOT_DIR/09_rails_chat/Gemfile"
  "$ROOT_DIR/15_rails_secure_chat/Gemfile"
  "$ROOT_DIR/18_rails_agent_job/Gemfile"
  "$ROOT_DIR/20_cve_scanner/Gemfile"
  "$ROOT_DIR/30_sqlite_persistence/Gemfile"
)

echo "Phronomy dependency source:"
if [[ -n "${PHRONOMY_PATH:-}" ]]; then
  echo "  local path: $PHRONOMY_PATH"
else
  echo "  definition: $ROOT_DIR/Gemfile.phronomy"
fi
echo

for gemfile in "${GEMFILES[@]}"; do
  bundle_dir="$(dirname "$gemfile")"
  display="${gemfile#"$ROOT_DIR"/}"
  echo "==> Updating $display"
  (
    cd "$bundle_dir"
    BUNDLE_GEMFILE="$gemfile" bundle update phronomy
    BUNDLE_GEMFILE="$gemfile" bundle exec ruby -e '
      require "phronomy"
      spec = Gem.loaded_specs.fetch("phronomy")
      puts "    Phronomy #{Phronomy::VERSION}"
      puts "    #{spec.full_gem_path}"
    '
  )
  echo
done

echo "All bundle lockfiles were updated."
echo

if [[ -n "${PHRONOMY_PATH:-}" ]]; then
  echo "Keep PHRONOMY_PATH set for verification so local bundles resolve the same checkout:"
  printf '  export PHRONOMY_PATH=%q\n' "$PHRONOMY_PATH"
  echo "  ./scripts/verify_examples.sh"
  echo "  (cd 30_sqlite_persistence && bundle exec rspec)"
else
  echo "Next:"
  echo "  ./scripts/verify_examples.sh"
  echo "  (cd 30_sqlite_persistence && bundle exec rspec)"
fi
