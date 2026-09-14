# frozen_string_literal: true

require_relative "../shared/llm_config"
require_relative "majority"
require_relative "agents"

mode = ARGV.fetch(0, "basic")
raise ArgumentError, "mode must be basic or evaluated" unless %w[basic evaluated].include?(mode)

question = "Can automated tests help detect regressions in a Ruby application?"
listener = ->(event) { warn "Agent event: #{event.type}" }

result = if mode == "basic"
  agents = Array.new(3) { MajorityVoter.new(on_event: listener) }
  AsyncMajority.run_async(agents, question: question)
else
  pairs = Array.new(3) do
    {voter: MajorityVoter.new(on_event: listener), evaluator: MajorityEvaluator.new(on_event: listener)}
  end
  AsyncMajority.run_evaluated_async(pairs, question: question)
end

begin
  report = result.wait_result
  puts "Decision: #{report.fetch(:decision)}"
  puts "Votes: #{report.fetch(:counts)}"
  report.fetch(:outcomes).each do |outcome|
    puts "Voter #{outcome.index}: #{outcome.status} #{outcome.value || outcome.error&.message}"
  end
rescue Phronomy::ExecutionTimeoutError, Phronomy::ExecutionCancellationError => error
  warn error.message
  error.outcomes.each { |outcome| warn "Voter #{outcome.index}: #{outcome.status}" }
  raise
end
