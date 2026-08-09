# frozen_string_literal: true

require "phronomy"
require_relative "../shared/llm_config"
require_relative "state"
require_relative "reviewers"
require_relative "improver"
require_relative "tracer"
require_relative "guardrails"

class LocalLlmJudge < Phronomy::Eval::Scorer::LlmJudge
  def score(actual:, expected:, input: nil)
    prompt = format(
      Phronomy::Eval::Scorer::LlmJudge::DEFAULT_PROMPT,
      input: input.to_s,
      expected: expected.to_s,
      actual: actual.to_s
    )
    chat = RubyLLM.chat(
      model: LLMConfig::MODEL,
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

def review_chunk(agent_class, chunk_text)
  agent = agent_class.new(knowledge: [agent_class.review_knowledge])
  agent.invoke(chunk_text)[:output].to_s.strip
end

def review_all_chunks(agent_class, chunks, source_code)
  texts = chunks.map { |chunk| chunk[:text] }
  texts = [source_code] if texts.empty?
  texts.each_with_index.filter_map do |chunk_text, index|
    puts "[#{agent_class.name}] chunk #{index + 1}/#{texts.size}"
    output = review_chunk(agent_class, chunk_text)
    output unless output.empty?
  rescue => e
    warn "[#{agent_class.name}] chunk #{index + 1}/#{texts.size}: #{e.class}: #{e.message}"
    nil
  end.join("\n")
end

def run_parallel_reviews(state)
  reviewers = {
    security: SecurityReviewerAgent,
    performance: PerformanceReviewerAgent,
    readability: ReadabilityReviewerAgent,
    abstraction: AbstractionConsistencyReviewerAgent
  }
  threads = reviewers.map do |key, agent_class|
    Thread.new do
      [key, review_all_chunks(agent_class, state.chunks, state.source_code)]
    end
  end
  threads.map(&:value).to_h
end

def build_eval_scores(state)
  judge = LocalLlmJudge.new(model: LLMConfig::MODEL)
  runner = Phronomy::Eval::Runner.new(scorer: judge)
  priority = state.priority || "security"

  review_dataset = Phronomy::Eval::Dataset.from_array([{
    input: "Ruby code review for #{priority}:\n#{state.source_code[0, 400]}",
    expected: "specific code issues with severity levels and line references"
  }])
  review_score = runner.run(
    review_dataset,
    ->(_input) { state.reviews[priority.to_sym].to_s }
  ).first.score

  improve_dataset = Phronomy::Eval::Dataset.from_array([{
    input: state.reviews[priority.to_sym].to_s,
    expected: "improved Ruby code in a ```ruby``` block addressing the identified issues"
  }])
  improve_score = runner.run(
    improve_dataset,
    ->(_input) { state.improved_code.to_s }
  ).first.score

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

def build_pipeline
  workflow = nil

  workflow = Phronomy::Workflow.define(ReviewState) do
    initial :load_and_split

    state :load_and_split, action: LOAD_AND_SPLIT_NODE

    state :parallel_review
    entry :parallel_review, lambda { |state|
      snapshot = state.merge({})
      thread_id = state.thread_id
      Thread.new do
        begin
          reviews = Phronomy.configuration.tracer.trace("parallel_review", input: snapshot.file_path) do |_span|
            [run_parallel_reviews(snapshot), nil]
          end
          workflow.signal(
            thread_id: thread_id,
            event: :reviews_completed,
            payload: {reviews: reviews}
          )
        rescue => e
          workflow.signal(
            thread_id: thread_id,
            event: :reviews_completed,
            payload: {error: e}
          )
        end
      end
      state
    }

    wait_state :awaiting_priority

    state :improve
    entry :improve, lambda { |state|
      snapshot = state.merge({})
      thread_id = state.thread_id
      Thread.new do
        begin
          priority = snapshot.priority || "security"
          review_text = snapshot.reviews[priority.to_sym].to_s
          max_improve_chars = [(LLMConfig::EFFECTIVE_CONTEXT_WINDOW - IMPROVE_OVERHEAD_TOKENS) * 4, 1].max
          raw_source = snapshot.chunks.first&.dig(:text) || snapshot.source_code
          source_excerpt = raw_source[0, max_improve_chars]
          user_prompt = IMPROVE_TEMPLATE.format(
            priority: priority,
            source_excerpt: source_excerpt,
            char_count: source_excerpt.length,
            review_text: review_text
          )

          agent_id = "review-#{File.basename(snapshot.file_path, ".rb")}"
          agent = begin
            ImproverAgent.load(agent_id, persistence: IMPROVER_PERSISTENCE)
          rescue Phronomy::Persistence::NotFoundError
            ImproverAgent.create(
              agent_id: agent_id,
              knowledge: [IMPROVEMENT_POLICY],
              persistence: IMPROVER_PERSISTENCE
            )
          end

          improved = +""
          puts "\n[ImproverAgent] Generating improvements (streaming)..."
          result = agent.stream({message: user_prompt, priority: priority}) do |event|
            if event.type == :token
              token = event.payload[:content].to_s
              print token
              $stdout.flush
              improved << token
            end
          end
          final_output = (result.is_a?(Array) ? result.first : result)&.dig(:output).to_s
          improved << final_output if improved.empty? && !final_output.empty?
          puts

          begin
            CODE_OUTPUT_GUARDRAIL.call(improved)
            puts "[OutputFilter] Output validation passed."
          rescue Phronomy::FilterBlockError => e
            puts "[OutputFilter] Warning: #{e.message}"
          end

          workflow.signal(
            thread_id: thread_id,
            event: :improvement_completed,
            payload: {improved_code: improved}
          )
        rescue => e
          workflow.signal(
            thread_id: thread_id,
            event: :improvement_completed,
            payload: {error: e}
          )
        end
      end
      state
    }

    state :evaluate
    entry :evaluate, lambda { |state|
      snapshot = state.merge({})
      thread_id = state.thread_id
      Thread.new do
        begin
          scores = Phronomy.configuration.tracer.trace("evaluate", input: snapshot.priority) do |_span|
            [build_eval_scores(snapshot), nil]
          end
          workflow.signal(
            thread_id: thread_id,
            event: :evaluation_completed,
            payload: {eval_scores: scores}
          )
        rescue => e
          workflow.signal(
            thread_id: thread_id,
            event: :evaluation_completed,
            payload: {error: e}
          )
        end
      end
      state
    }

    transition from: :load_and_split, to: :parallel_review
    transition from: :parallel_review, on: :reviews_completed, to: :awaiting_priority,
      action: ->(state, event) { state.merge(reviews: event_payload!(event).fetch(:reviews)) }
    transition from: :awaiting_priority, on: :proceed, to: :improve
    transition from: :improve, on: :improvement_completed, to: :evaluate,
      action: ->(state, event) { state.merge(improved_code: event_payload!(event).fetch(:improved_code)) }
    transition from: :evaluate, on: :evaluation_completed, to: :__finish__,
      action: ->(state, event) { state.merge(eval_scores: event_payload!(event).fetch(:eval_scores)) }
  end

  workflow
end
