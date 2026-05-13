#!/usr/bin/env ruby
# frozen_string_literal: true

# 20 CVE Scanner — Web UI entry point.
# Starts a Rails development server on http://localhost:3020.
#
# Usage:
#   bundle exec ruby run.rb
#
# Then open http://localhost:3020 in your browser.

require_relative "../shared/llm_config"

exec "bundle exec rails server -p 3020 -e development"
