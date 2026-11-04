#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
export BUNDLE_GEMFILE="$PWD/30_sqlite_persistence/Gemfile"

for probe in workflow_native.rb competing_workers/run.rb siblings.rb grandchild.rb tool_failure/run.rb tool_effect_crash.rb; do
  printf '\n== %s ==\n' "$probe"
  bundle exec ruby "spec/hosted_workers/$probe"
done
