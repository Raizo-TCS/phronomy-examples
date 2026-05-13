# frozen_string_literal: true

# Load all CVE scanner library files explicitly.
# These live under lib/cve_scanner/ and are not autoloaded by Zeitwerk
# (to avoid constant-definition conflicts with the application module).

require "phronomy"

shared_llm_config = File.expand_path("../../../shared/llm_config", __dir__)
require shared_llm_config

# Load tools before agents (agents reference tool constants at class-definition time).
Dir[Rails.root.join("lib/cve_scanner/*_tool.rb")].sort.each { |f| require f }
Dir[Rails.root.join("lib/cve_scanner/*_state.rb")].sort.each { |f| require f }
Dir[Rails.root.join("lib/cve_scanner/*.rb")].sort.each do |file|
  require file  # Already-loaded files are no-ops
end
