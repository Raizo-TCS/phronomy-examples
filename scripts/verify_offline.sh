#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "$root_dir"

python3 scripts/verify_current_api.py
bundle exec ruby -e '
  require "rbconfig"
  files = Dir.glob("**/*.rb").reject { |path| path.split("/").include?("vendor") }
  failed = files.reject { |path| system(RbConfig.ruby, "-c", path, out: File::NULL) }
  abort "Ruby syntax failed: #{failed.join(", ")}" unless failed.empty?
  puts "Ruby syntax: #{files.length} files passed"
'
bundle exec rspec spec --format progress
(
  cd -- "$root_dir/30_sqlite_persistence"
  bundle exec rspec --format progress
  bundle exec ruby run.rb
)

echo "Offline verification passed (protocol stubs and real SQLite; no live LLM or PostgreSQL)."
