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
  Phronomy.const_defined?(:Storage, false) && Phronomy::PersistenceComposition.respond_to?(:in_memory)
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

abort "The selected core does not support Storage SPI 2" unless
  Phronomy::Storage::Backend::REQUIRED_CAPABILITIES[:spi_version] == 2 &&
    Phronomy::Storage::View.method_defined?(:records)
puts "Neutral Storage SPI 2 preflight PASS"

abort "The selected core lacks the r8 Context/Tool framework; set PHRONOMY_PATH to the matching checkout" unless
  Phronomy.const_defined?(:Context, false) && Phronomy::Context.const_defined?(:Assembly, false) &&
    Phronomy::Context.const_defined?(:PromptTemplate, false) && Phronomy::Tool.const_defined?(:Authorization, false)
abort "The selected core still exposes the removed Agent Context API" if
  Phronomy::Agent.const_defined?(:Context, false) || Phronomy::Agent.const_defined?(:LLMInputPatch, false)
abort "The selected core lacks Execution.submit" unless Phronomy::Execution.respond_to?(:submit)
puts "r8 unit 1 Context/Tool/Execution API preflight PASS"

abort "The selected core lacks r8 atomic admission; set PHRONOMY_PATH to the matching checkout" unless
  Phronomy::Persistence.method_defined?(:atomic) &&
    Phronomy::Agent.const_defined?(:Admission, false) &&
    Phronomy::MultiAgent.const_defined?(:ReservedChildAdmission, false)
puts "Atomic parent/child admission API preflight PASS"

abort "The selected core still exposes the removed shared domain facade" if
  Phronomy::Persistence.respond_to?(:in_memory) || Phronomy::Persistence.method_defined?(:agents) ||
    Phronomy::Persistence.method_defined?(:execution_result)
abort "The selected core lacks domain-owned durable operations" unless
  Phronomy::Agent::Store.method_defined?(:participate) && Phronomy::MultiAgent::Store.method_defined?(:result)
puts "r8 unit 3 Persistence/domain composition API preflight PASS"

abort "The selected core lacks r8 unit 4 execution/coordination boundaries" unless
  Phronomy::Agent::Base.method_defined?(:start_reserved_async) &&
    Phronomy::Agent::Store.method_defined?(:observe_execution) &&
    Phronomy::MultiAgent.const_defined?(:Handoff, false) &&
    Phronomy::PersistenceComposition::Stores.members.include?(:multi_agent)
abort "The selected core still exposes Agent-owned Handoff" if Phronomy::Agent.const_defined?(:Handoff, false)
puts "r8 unit 4 Agent/MultiAgent API preflight PASS"
