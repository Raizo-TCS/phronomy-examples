# DX05-C Parallel review result composition

A review application should choose reviewers and decide how to use their findings.
It should not have to synchronize a completion counter for every group of async
calls. Example 14 now delegates that bookkeeping to the existing C13 Execution
result API while keeping review-specific decisions in the application.

This change is based on examples `10f26938136880298bd270f6ddcd9c91a1d2bf15`
and uses core `c673c958cd15407fb4552b6e0eca42175ec73ab7` without modifying it.
The follow-up design implements C before B (P2, then P3). DX05-B/D/E remain
separate work.

## Responsibility and behavior

| Owner | Responsibility |
|---|---|
| Application | Reviewer selection, chunk creation, finding extraction, reviewer/chunk ordering, warnings and exclusion of failed findings |
| C04 Agent | Start and execute each review through the existing `invoke_async` operation |
| C13 Execution | `map` turns extraction failures into failed derived results; `all_settled` observes every input and returns indexed outcomes |
| C02 Workflow | Receive the one composed completion through the existing application `signal_completion` bridge |

Core already synchronizes its ResultCollector with a Mutex. This change neither
removes the need for internal synchronization nor moves reviewer-specific
business logic into core. It removes the duplicate application counter, Mutex,
last-result decision and private TaskResult settlement calls. No Contract or
Contract dependency pair is added. The shared core graph remains 16 Contracts,
32 static pairs and no Contract cycles.

All calls start before aggregation. Successful outputs are trimmed and joined in
source-chunk order within each reviewer, independent of completion order. A child
that fails during construction, submission, asynchronous execution or output
conversion is warned about and excluded. A cancelled child is excluded too;
peers are not cancelled. Missing/nil/blank output remains an empty contribution.
When every review fails, all reviewer keys remain present with empty strings.
An empty string is absence of a finding, not evidence that the source is safe.

Warnings move from each child's completion to final aggregation, in input order.
If a peer never settles, aggregation and those warnings remain pending. There is
no implicit timeout, retry, fail-fast cancellation or physical-worker shutdown.
An exception in the application's aggregation (including its warning sink)
fails the returned composed result instead of leaving a manual counter pending.
Agent scope/unload is DX05-E and is not included here.

## Before

This is the complete previous `start_parallel_reviews` method. If extraction in
an `on_complete` observer raises, the callback can exit before decrementing
`remaining`, leaving the combined task pending.

```ruby
def start_parallel_reviews(state)
  texts = review_texts(state)
  jobs = REVIEWERS.flat_map do |key, agent_class|
    texts.each_with_index.map { |text, index| [key, agent_class, text, index] }
  end

  result_task = Phronomy::TaskResult.deferred(name: "example-14-parallel-reviews")
  outputs = REVIEWERS.to_h { |key, _| [key, Array.new(texts.length)] }
  mutex = Mutex.new
  remaining = jobs.length

  if remaining.zero?
    result_task.complete(REVIEWERS.to_h { |key, _| [key, ""] })
    return result_task
  end

  settle_one = lambda do |key, index, output, error|
    warn "[#{REVIEWERS.fetch(key).name}] chunk #{index + 1}/#{texts.size}: #{error.class}: #{error.message}" if error

    completed = false
    reviews = nil
    mutex.synchronize do
      outputs[key][index] = output.to_s unless error
      remaining -= 1
      if remaining.zero?
        completed = true
        reviews = outputs.transform_values { |values| values.compact.reject(&:empty?).join("\n") }
      end
    end
    result_task.complete(reviews) if completed
  end

  jobs.each do |key, agent_class, chunk_text, index|
    puts "[#{agent_class.name}] chunk #{index + 1}/#{texts.size}"
    begin
      agent = agent_class.new(knowledge: [agent_class.review_knowledge])
      operation = agent.invoke_async(chunk_text)
      operation.on_complete do |result, error|
        output = error ? nil : result[:output].to_s.strip
        settle_one.call(key, index, output, error)
      end
    rescue => error
      settle_one.call(key, index, nil, error)
    end
  end

  result_task
end
```

## After

The complete replacement method has two steps: start and transform each review,
then select and group its indexed outcomes. It uses the existing `review_texts`
helper and reviewer definitions without changing their meaning.

```ruby
def start_parallel_reviews(state)
  texts = review_texts(state)
  jobs = REVIEWERS.flat_map do |key, agent_class|
    texts.each_with_index.map { |text, index| [key, agent_class, text, index] }
  end

  tasks = jobs.map do |_key, agent_class, chunk_text, index|
    puts "[#{agent_class.name}] chunk #{index + 1}/#{texts.size}"
    begin
      agent = agent_class.new(knowledge: [agent_class.review_knowledge])
      agent.invoke_async(chunk_text).map { |result| result[:output].to_s.strip }
    rescue StandardError => error
      Phronomy::TaskResult.failed(error, name: "example-14-review-start")
    end
  end

  Phronomy::TaskResult.all_settled(tasks).map do |outcomes|
    outputs = REVIEWERS.to_h { |key, _| [key, Array.new(texts.length)] }
    outcomes.each do |outcome|
      key, agent_class, _text, index = jobs.fetch(outcome.index)
      if outcome.status == :completed
        outputs.fetch(key)[index] = outcome.value
      else
        error = outcome.error
        warn "[#{agent_class.name}] chunk #{index + 1}/#{texts.size}: #{error.class}: #{error.message}"
      end
    end
    outputs.transform_values { |values| values.compact.reject(&:empty?).join("\n") }
  end
end
```

## Acceptance

Run against the paired core checkout:

```bash
export PHRONOMY_PATH=/absolute/path/to/reviewed/core
bundle check
bundle exec rspec spec/parallel_review_composition_spec.rb
bundle exec rspec spec
bash scripts/verify_offline.sh
```

The focused suite covers no reviewers, no texts, one already-settled result,
whole-source fallback, reverse and concurrent completion, construction and
submission failures, asynchronous failures, cancellation, delayed output
conversion failure, blank output, all-child failure and an aggregation error.
It also runs the real four reviewer Agents and Workflow through approval wait,
stubbing only the HTTP LLM protocol. The controlled completion cases use private
TaskResult factories/settlement only as test drivers, not application APIs.

The existing examples CI runs these root specs under Ruby 3.2, 3.3 and 3.4 with
the pinned core commit. Live LLM quality, a permanently unsettled child and
DX05-D/E lifecycle features are not certified by these acceptance tests.
