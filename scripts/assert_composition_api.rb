# frozen_string_literal: true

require "phronomy"

abort "The selected core lacks TaskResult/Execution" unless
  Phronomy.const_defined?(:TaskResult, false) && Phronomy.const_defined?(:Execution, false)
abort "The selected core still exposes the removed Task constant" if Phronomy.const_defined?(:Task, false)
abort "The selected core lacks flat_map/all_settled" unless
  Phronomy::TaskResult.method_defined?(:flat_map) && Phronomy::TaskResult.respond_to?(:all_settled)
abort "The selected core lacks the context-aware Blocking API" unless
  Phronomy::Blocking.method(:call_async).parameters.include?([:key, :invocation_context])
abort "The selected core lacks the integrated Execution entrances" unless
  Phronomy::Execution.respond_to?(:run_async) && Phronomy::Execution.respond_to?(:run)

puts "TaskResult/Execution API preflight PASS"
