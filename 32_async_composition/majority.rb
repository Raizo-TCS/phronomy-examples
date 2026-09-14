# frozen_string_literal: true

require "phronomy"

# Vote interpretation, abstention and the decision rule belong to this app.
# A decision needs a strict majority of ALL registered voters. A failed or
# cancelled vote counts as an abstention; ties and empty input are inconclusive.
module AsyncMajority
  def self.vote(response)
    label = response.fetch(:output).to_s.strip.upcase
    raise ArgumentError, "expected YES or NO, got #{label.inspect}" unless %w[YES NO].include?(label)

    label
  end

  def self.decide(outcomes)
    counts = {"YES" => 0, "NO" => 0, "ABSTAIN" => 0}
    outcomes.each do |outcome|
      if outcome.status == :completed
        counts.fetch(outcome.value) # A malformed application vote is an error.
        counts[outcome.value] += 1
      else
        counts["ABSTAIN"] += 1
      end
    end
    winner = %w[YES NO].find { |label| counts[label] > outcomes.length / 2.0 }
    {decision: winner || "INCONCLUSIVE", counts: counts, outcomes: outcomes}
  end

  # Basic example: the short synchronous vote conversion uses map.
  def self.run_async(agents, question:, timeout: 30, invocation_context: nil)
    Phronomy::Execution.run_async(agents, timeout: timeout,
      invocation_context: invocation_context) do |agent, execution|
      agent.invoke_async(question, invocation_context: execution.invocation_context)
        .map { |response| vote(response) }
    end.map { |outcomes| decide(outcomes) }
  end

  # Extended example: each JOB includes a separate evaluator Agent's result.
  # Each pair has distinct live Agent instances; no voter/evaluator is invoked
  # concurrently a second time. Both operations explicitly share this run's scope.
  def self.run_evaluated_async(pairs, question:, timeout: 30, invocation_context: nil)
    Phronomy::Execution.run_async(pairs, timeout: timeout,
      invocation_context: invocation_context) do |pair, execution|
      pair.fetch(:voter).invoke_async(question,
        invocation_context: execution.invocation_context).flat_map do |response|
        pair.fetch(:evaluator).invoke_async(
          "Question: #{question}\nProposed answer: #{response.fetch(:output)}\n" \
          "Return YES if the proposed answer is supported; otherwise return NO.",
          invocation_context: execution.invocation_context
        ).map { |evaluation| vote(evaluation) }
      end
    end.map { |outcomes| decide(outcomes) }
  end
end
