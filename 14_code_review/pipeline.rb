# frozen_string_literal: true

require "phronomy"
require_relative "../shared/llm_config"
require_relative "state"
require_relative "reviewers"
require_relative "improver"
require_relative "tracer"
require_relative "guardrails"

# Application-level LLM quality judge. Phronomy::Testing::Eval is intentionally
# not used in this production-style example.
class LocalLlmJudge
  DEFAULT_PROMPT = <<~PROMPT
    You are an impartial judge evaluating the quality of an AI assistant response.
    Rate the response on a scale from 0.0 (completely wrong or unhelpful) to 1.0 (perfect).
    Respond with ONLY a single decimal number between 0.0 and 1.0 — no other text.

    Question: %<input>s
    Expected answer: %<expected>s
    Actual response: %<actual>s

    Score:
  PROMPT

  def initialize(model: LLMConfig::MODEL)
    @model = model
  end

  # This method performs blocking third-party I/O and must therefore only be
  # called from the Runtime OffloadPool in this example.
  def score(actual:, expected:, input: nil)
    prompt = format(
      DEFAULT_PROMPT,
      input: input.to_s,
      expected: expected.to_s,
      actual: actual.to_s
    )
    chat = RubyLLM.chat(
      model: @model,
      **(LLMConfig::PROVIDER ? {provider: LLMConfig::PROVIDER, assume_model_exists: true} : {})
    )
    chat.ask(prompt).content.to_s.strip.scan(/-?\d+\.?\d*/).first.to_f.clamp(0.0, 1.0)
  rescue => e
    warn "[LocalLlmJudge] Scoring failed: #{e.message}"
    0.0
  end
end

IMPROVER_PERSISTENCE = Phronomy::Persistence::InMemory.new
CODE_OUTPUT_GUARDRAIL = CodeOutputGuardrail.new
REVIEW_OVERHEAD_TOKENS = 200 + REVIEWER_MAX_OUTPUT_TOKENS

REVIEWERS = {
  security: SecurityReviewerAgent,
  performance: PerformanceReviewerAgent,
  readability: ReadabilityReviewerAgent,
  abstraction: AbstractionConsistencyReviewerAgent
}.freeze

LOAD_AND_SPLIT_NODE = lambda do |state|
  Phronomy.configuration.tracer.trace("load_and_split", input: state.file_path) do |_span|
    available_tokens = [LLMConfig::EFFECTIVE_CONTEXT_WINDOW - REVIEW_OVERHEAD_TOKENS, 1].max
    source_tokens = (state.source_code.length / 4.0).ceil
    chunk_size = [[available_tokens * 4, state.source_code.length].min, 1].max
    splitter = Phronomy::VectorStore::Splitter::RecursiveSplitter.new(
      chunk_size: chunk_size,
      chunk_overlap: [chunk_size / 20, 200].min
    )
    chunks = splitter.split({text: state.source_code, metadata: {file: state.file_path}})
    line_count = state.source_code.lines.count
    puts "[Splitter] #{line_count} lines (~#{source_tokens} tokens) -> #{chunks.size} chunk(s)"
    [state.merge(chunks: chunks), nil]
  end
end

def review_texts(state)
  texts = state.chunks.map { |chunk| chunk[:text] }
  texts.empty? ? [state.source_code] : texts
end

# Starts every reviewer/chunk Agent invocation without creating application
# Threads. The returned Task is only a completion handle; child Agent execution
# is coordinated by Phronomy's EventLoop/FSMSession runtime.
def start_parallel_reviews(state)
  texts = review_texts(state)
  jobs = REVIEWERS.flat_map do |key, agent_class|
    texts.each_with_index.map { |text, index| [key, agent_class, text, index] }
  end

  result_task = Phronomy::Task.deferred(name: "example-14-parallel-reviews")
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

def build_improvement_prompt(snapshot)
  priority = snapshot.priority || "security"
  review_text = snapshot.reviews[priority.to_sym].to_s
  max_improve_chars = [(LLMConfig::EFFECTIVE_CONTEXT_WINDOW - IMPROVE_OVERHEAD_TOKENS) * 4, 1].max
  raw_source = snapshot.chunks.first&.dig(:text) || snapshot.source_code
  source_excerpt = raw_source[0, max_improve_chars]

  IMPROVE_TEMPLATE.format(
    priority: priority,
    source_excerpt: source_excerpt,
    char_count: source_excerpt.length,
    review_text: review_text
  )
end

def load_or_create_improver(snapshot)
  agent_id = "review-#{File.basename(snapshot.file_path, ".rb")}"
  ImproverAgent.load(agent_id, persistence: IMPROVER_PERSISTENCE)
rescue Phronomy::Persistence::NotFoundError
  ImproverAgent.create(
    agent_id: agent_id,
    knowledge: [IMPROVEMENT_POLICY],
    persistence: IMPROVER_PERSISTENCE
  )
end

def start_improvement(snapshot)
  agent = load_or_create_improver(snapshot)
  user_prompt = build_improvement_prompt(snapshot)
  result_task = Phronomy::Task.deferred(name: "example-14-improvement")

  puts "
[ImproverAgent] Generating improvements..."
  operation = agent.invoke_async({message: user_prompt, priority: snapshot.priority || "security"})

  operation.on_complete do |result, error|
    if error
      result_task.fail(error)
      next
    end

    value = result&.dig(:output).to_s
    puts value

    begin
      CODE_OUTPUT_GUARDRAIL.call(value)
      puts "[OutputFilter] Output validation passed."
    rescue Phronomy::FilterBlockError => e
      puts "[OutputFilter] Warning: #{e.message}"
    end

    result_task.complete(value)
  end

  result_task
rescue => error
  result_task ||= Phronomy::Task.deferred(name: "example-14-improvement")
  result_task.fail(error)
  result_task
end

def build_quality_scores(state)
  judge = LocalLlmJudge.new(model: LLMConfig::MODEL)
  priority = state.priority || "security"

  review_score = judge.score(
    input: "Ruby code review for #{priority}:\n#{state.source_code[0, 400]}",
    expected: "specific code issues with severity levels and line references",
    actual: state.reviews[priority.to_sym].to_s
  )

  improve_score = judge.score(
    input: state.reviews[priority.to_sym].to_s,
    expected: "improved Ruby code in a ```ruby``` block addressing the identified issues",
    actual: state.improved_code.to_s
  )

  {
    review_quality: (review_score * 10).round(1),
    improvement_quality: (improve_score * 10).round(1)
  }
end

def event_payload!(event)
  payload = event.payload || {}
  raise payload[:error] if payload[:error]
  payload
end

def signal_completion(workflow, thread_id:, event:, operation:, key:)
  operation.on_complete do |value, error|
    workflow.signal(
      workflow_instance_id: workflow_instance_id,
      event: event,
      payload: error ? {error: error} : {key => value}
    )
  end
end

def build_pipeline
  workflow = nil

  workflow = Phronomy::Workflow.define(ReviewState) do
    initial :load_and_split

    state :load_and_split, action: LOAD_AND_SPLIT_NODE

    state :parallel_review
    entry :parallel_review, lambda { |state|
      snapshot = state.merge({})
      operation = start_parallel_reviews(snapshot)
      signal_completion(
        workflow,
        thread_id: state.workflow_instance_id,
        event: :reviews_completed,
        operation: operation,
        key: :reviews
      )
      state
    }

    wait_state :awaiting_priority

    state :improve
    entry :improve, lambda { |state|
      operation = start_improvement(state.merge({}))
      signal_completion(
        workflow,
        thread_id: state.workflow_instance_id,
        event: :improvement_completed,
        operation: operation,
        key: :improved_code
      )
      state
    }

    state :evaluate
    entry :evaluate, lambda { |state|
      snapshot = state.merge({})
      operation = Phronomy::Runtime.instance.offload.submit do
        Phronomy.configuration.tracer.trace("evaluate", input: snapshot.priority) do |_span|
          [build_quality_scores(snapshot), nil]
        end
      end
      signal_completion(
        workflow,
        thread_id: state.workflow_instance_id,
        event: :evaluation_completed,
        operation: operation,
        key: :quality_scores
      )
      state
    }

    transition from: :load_and_split, to: :parallel_review
    transition from: :parallel_review, on: :reviews_completed, to: :awaiting_priority,
      action: ->(state, event) { state.merge(reviews: event_payload!(event).fetch(:reviews)) }
    transition from: :awaiting_priority, on: :proceed, to: :improve
    transition from: :improve, on: :improvement_completed, to: :evaluate,
      action: ->(state, event) { state.merge(improved_code: event_payload!(event).fetch(:improved_code)) }
    transition from: :evaluate, on: :evaluation_completed, to: :__finish__,
      action: ->(state, event) { state.merge(quality_scores: event_payload!(event).fetch(:quality_scores)) }
  end

  workflow
end
