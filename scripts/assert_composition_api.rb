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

abort "The selected core lacks Storage composition; set PHRONOMY_PATH to the matching refactoring checkout" unless
  Phronomy.const_defined?(:Storage, false) && Phronomy::Persistence.respond_to?(:in_memory)
abort "The selected core still exposes the replaced Persistence Backend SPI" if
  Phronomy::Persistence.const_defined?(:InMemory, false) || Phronomy::Persistence.method_defined?(:build_transaction_view)
puts "Storage/Persistence composition API preflight PASS"

abort "The selected core lacks MultiAgent::HandoffRunner; set PHRONOMY_PATH to the matching refactoring checkout" unless
  Phronomy::MultiAgent.const_defined?(:HandoffRunner, false)
abort "The selected core still exposes Agent::HandoffRunner" if
  Phronomy::Agent.const_defined?(:HandoffRunner, false)
puts "MultiAgent HandoffRunner API preflight PASS"

abort "The selected core lacks MultiAgent::SharedState; set PHRONOMY_PATH to the matching refactoring checkout" unless
  Phronomy::MultiAgent.const_defined?(:SharedState, false)
abort "The selected core still exposes Agent::SharedState" if
  Phronomy::Agent.const_defined?(:SharedState, false)
puts "MultiAgent SharedState API preflight PASS"
