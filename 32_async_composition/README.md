# Async result composition and majority voting

`basic` is the minimal example. It groups Agent invocation, per-vote conversion,
fan-in, and the decision in one expression. `evaluated` adds an asynchronous
evaluation step to every JOB with `flat_map`.

```bash
bundle exec ruby 32_async_composition/run.rb basic
bundle exec ruby 32_async_composition/run.rb evaluated
```

Configure a Provider with the repository's shared LLM settings first. These
commands make three and six LLM requests respectively. Progress notifications
use the listener attached when each Agent is constructed.

The app chooses what to return from each JOB. Basic mode returns a parsed vote;
evaluated mode returns the evaluator's parsed vote. Execution waits for these
final results and returns an input-order `TaskResult::Outcome` array. It does
not choose the interpretation of a vote or a majority rule. This example
requires more than half of all registered votes for a decision. Errors count
as abstentions; empty input and ties are inconclusive. Correlated model answers
can agree and still be wrong, so the result is a voting decision, not a guarantee.

The 30-second Execution timeout ends at fan-in. The outer `map` performs the
decision after that scope. If it needs slow I/O, attach an outer `flat_map` and
give that operation its own timeout:

```ruby
require "json"

saved = AsyncMajority.run_async(agents, question: question).flat_map do |report|
  Phronomy::Blocking.call_async(timeout: 5) do
    File.write("decision.json", JSON.generate(report.slice(:decision, :counts)))
    report
  end
end
report = saved.wait_result
```

This adds a separate five-second budget; it does not extend the fan-in deadline.
Blocking uses the existing OffloadPool. The app selects that boundary because
file I/O can block. A timeout reports logical failure and does not roll back a
write or guarantee that a running worker has stopped.

For results already started elsewhere, `TaskResult.all_settled(results)` only
observes them. Within a new Execution, use `execution.observe(result).map { ... }`
to put new per-JOB transformations in that scope without cancelling the source.
If a JOB starts two required operations, return a result that waits for both;
unreturned work is not automatically registered as another JOB.

This example needs the new TaskResult/Execution core commit specified by the
application package. The old 0.25.0 API is not sufficient.
