# frozen_string_literal: true

require "phronomy"
require_relative "../shared/llm_config"
require_relative "state"
require_relative "reviewers"
require_relative "improver"
require_relative "tracer"
require_relative "guardrails"

# Custom LLM judge scorer that respects the local provider configuration.
# Phronomy::Eval::Scorer::LlmJudge calls RubyLLM.chat without a provider,
# which causes routing failures when using locally-hosted models.
class LocalLlmJudge < Phronomy::Eval::Scorer::LlmJudge
  def score(actual:, expected:, input: nil)
    prompt = format(
      Phronomy::Eval::Scorer::LlmJudge::DEFAULT_PROMPT,
      input: input.to_s, expected: expected.to_s, actual: actual.to_s
    )
    chat = RubyLLM.chat(
      model: LLMConfig::MODEL,
      provider: LLMConfig::PROVIDER,
      assume_model_exists: true
    )
    chat.ask(prompt).content.to_s.strip.scan(/-?\d+\.?\d*/).first.to_f.clamp(0.0, 1.0)
  rescue => e
    warn "[LocalLlmJudge] Scoring failed: #{e.message}"
    0.0
  end
end

# Per-thread conversation history for ImproverAgent.
# Keys are thread_id strings; values are Arrays of RubyLLM::Message.
# Updated from the :done event payload after each stream call.
REVIEW_SESSIONS = Hash.new { |h, k| h[k] = [] }

# OutputGuardrail instance reused across improve nodes.
CODE_OUTPUT_GUARDRAIL = CodeOutputGuardrail.new

# ---- Node: load_and_split ----
# Reads the source file and splits it into chunks for context management.
# Overhead tokens reserved for system prompt, static knowledge, and output.
# The remainder (context_window - REVIEW_OVERHEAD_TOKENS) is available for
# source content. chunk_size is calculated dynamically in LOAD_AND_SPLIT_NODE
# based on actual source size so the fewest possible chunks are used.
# Ruby code is approximately 4 chars/token.
REVIEW_OVERHEAD_TOKENS = 200 + REVIEWER_MAX_OUTPUT_TOKENS

LOAD_AND_SPLIT_NODE = lambda do |state|
  Phronomy.configuration.tracer.trace("load_and_split", input: state.file_path) do |_span|
    available_tokens = LLMConfig::EFFECTIVE_CONTEXT_WINDOW - REVIEW_OVERHEAD_TOKENS
    source_tokens    = (state.source_code.length / 4.0).ceil
    # Maximise chunk_size so the fewest chunks are needed. When the source fits
    # entirely within the available budget it becomes a single chunk.
    chunk_size = [available_tokens * 4, state.source_code.length].min
    splitter = Phronomy::Splitter::RecursiveSplitter.new(
      chunk_size: chunk_size,
      chunk_overlap: [chunk_size / 20, 200].min
    )
    chunks = splitter.split({ text: state.source_code, metadata: { file: state.file_path } })
    line_count = state.source_code.lines.count
    puts "[Splitter] #{line_count} lines (~#{source_tokens} tokens) → #{chunks.size} chunk(s) " \
         "(chunk_size: #{chunk_size} chars, available: #{available_tokens} tokens)"
    [state.merge(chunks: chunks), nil]
  end
end

# Seconds without receiving a streaming token before treating the LLM call as hung.
# A watchdog thread raises in the branch thread so the parallel error handler can recover.
REVIEWER_ACTIVITY_TIMEOUT = 90

# Calls one reviewer agent on a single chunk using streaming.
# A watchdog thread monitors token activity; if no token arrives within
# REVIEWER_ACTIVITY_TIMEOUT seconds the watchdog raises RuntimeError in the
# calling thread, which is rescued by PARALLEL_REVIEW_NODE's error-handling block.
def review_chunk_streaming(agent_class, chunk_text, idx, total)
  output = +""
  last_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  branch_thread = Thread.current

  watchdog = Thread.new do
    loop do
      sleep 10
      idle = Process.clock_gettime(Process::CLOCK_MONOTONIC) - last_at
      if idle > REVIEWER_ACTIVITY_TIMEOUT
        branch_thread.raise(
          RuntimeError,
          "[#{agent_class.name}] chunk #{idx}/#{total}: no token for #{idle.to_i}s (activity timeout)"
        )
        break
      end
    end
  end

  begin
    agent_class.new.stream(chunk_text) do |event|
      if event.type == :token
        output << event.payload[:content].to_s
        last_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  ensure
    watchdog.kill
  end

  output.strip
end

# Runs a single reviewer agent over all chunks and concatenates findings.
# Each chunk is independently sent to keep every call within the context window.
def review_all_chunks(agent_class, chunks, source_code)
  texts = chunks.map { |c| c[:text] }
  texts = [source_code] if texts.empty?
  texts.each_with_index.map do |chunk_text, idx|
    print chunks.size > 1 ? "." : ""
    $stdout.flush
    output = review_chunk_streaming(agent_class, chunk_text, idx + 1, texts.size)
    warn "[DEBUG][#{agent_class.name}] chunk=#{idx + 1}/#{texts.size} " \
         "input_chars=#{chunk_text.length} output_chars=#{output.length} " \
         "output_empty=#{output.empty?}"
    warn "[DEBUG][#{agent_class.name}] raw_output=#{output.inspect[0, 300]}" unless output.empty?
    output
  end.reject { |r| r.empty? }.join("\n")
end

# ---- Parallel branches for the review node ----
# Each branch iterates over all source chunks to avoid context-length errors.
# Findings from all chunks are concatenated.
SECURITY_BRANCH = lambda do |state|
  Phronomy.configuration.tracer.trace("security_review", input: state.file_path) do |_span|
    findings = review_all_chunks(SecurityReviewerAgent, state.chunks, state.source_code)
    [{ reviews: { security: findings } }, nil]
  end
end

PERFORMANCE_BRANCH = lambda do |state|
  Phronomy.configuration.tracer.trace("performance_review", input: state.file_path) do |_span|
    findings = review_all_chunks(PerformanceReviewerAgent, state.chunks, state.source_code)
    [{ reviews: { performance: findings } }, nil]
  end
end

READABILITY_BRANCH = lambda do |state|
  Phronomy.configuration.tracer.trace("readability_review", input: state.file_path) do |_span|
    findings = review_all_chunks(ReadabilityReviewerAgent, state.chunks, state.source_code)
    [{ reviews: { readability: findings } }, nil]
  end
end

ABSTRACTION_BRANCH = lambda do |state|
  Phronomy.configuration.tracer.trace("abstraction_review", input: state.file_path) do |_span|
    findings = review_all_chunks(AbstractionConsistencyReviewerAgent, state.chunks, state.source_code)
    [{ reviews: { abstraction: findings } }, nil]
  end
end

# ---- Node: parallel_review (application-level parallel execution) ----
# Runs four reviewer agents concurrently using Ruby threads.
# This is an application-level parallel pattern; phronomy does not provide
# a built-in parallel node abstraction.
# Errors from individual branches are logged (best_effort semantics);
# the partial reviews collected so far are merged into the state.
PARALLEL_REVIEW_NODE = lambda do |state|
  branches = [SECURITY_BRANCH, PERFORMANCE_BRANCH, READABILITY_BRANCH, ABSTRACTION_BRANCH]
  results = []
  errors = []
  mutex = Mutex.new

  threads = branches.map do |branch|
    Thread.new do
      result = branch.call(state)
      mutex.synchronize { results << result } if result
    rescue => e
      mutex.synchronize { errors << e }
    end
  end

  threads.each(&:join)

  errors.each { |e| warn "[parallel_review] branch error: #{e.message}" }

  # Deep-merge all branch results into a single Hash update.
  merged = results.each_with_object({}) do |r, acc|
    r.each do |key, val|
      if acc[key].is_a?(Hash) && val.is_a?(Hash)
        acc[key] = acc[key].merge(val)
      else
        acc[key] = val
      end
    end
  end
  merged
end

# ---- Node: improve ----
# Calls ImproverAgent with streaming, using PromptTemplate for the user message.
# ConversationManager carries context across repeated review runs.
#
# Context management: source_excerpt is taken from the first splitter chunk
# and capped to the tokens available after overhead, so the combined tokens for
# system prompt + source + review + history + output stay within
# LLMConfig::CONTEXT_WINDOW. The cap is computed at runtime from the actual
# context window size so larger deployments automatically pass more code.
IMPROVE_NODE = lambda do |state|
  Phronomy.configuration.tracer.trace("improve", input: state.priority) do |_span|
    priority    = state.priority || "security"
    review_text = state.reviews[priority.to_sym].to_s

    # Use the first splitter chunk (or fall back to raw source) and cap to the
    # available budget calculated from the actual context window at runtime.
    max_improve_chars = (LLMConfig::EFFECTIVE_CONTEXT_WINDOW - IMPROVE_OVERHEAD_TOKENS) * 4
    raw_source        = state.chunks.first&.dig(:text) || state.source_code
    source_excerpt    = raw_source[0, max_improve_chars]
    char_count        = source_excerpt.length
    puts "[ImproverAgent] Source excerpt: #{char_count} / #{state.source_code.length} chars" \
         "#{char_count < state.source_code.length ? " (truncated)" : ""}"

    user_prompt = IMPROVE_TEMPLATE.format(
      priority:       priority,
      source_excerpt: source_excerpt,
      char_count:     char_count,
      review_text:    review_text
    )

    thread_id = "review-#{File.basename(state.file_path, ".rb")}"
    improved  = +""

    print "\n[ImproverAgent] Generating improvements (streaming)...\n"
    ImproverAgent.new.stream(
      { message: user_prompt, priority: priority },
      messages: REVIEW_SESSIONS[thread_id], thread_id: thread_id
    ) do |event|
      case event.type
      when :token
        content = event.payload[:content]
        if content
          print content
          $stdout.flush
          improved << content
        end
      when :done
        puts "\n"
        REVIEW_SESSIONS[thread_id] = event.payload[:messages]
      end
    end

    begin
      CODE_OUTPUT_GUARDRAIL.run!(improved)
      puts "[OutputGuardrail] Output validation passed."
    rescue Phronomy::GuardrailError => e
      puts "[OutputGuardrail] Warning: #{e.message}"
    end

    [state.merge(improved_code: improved), nil]
  end
end

# ---- Node: evaluate ----
# Scores review quality and improvement quality using LLMJudge via Eval::Runner.
EVALUATE_NODE = lambda do |state|
  Phronomy.configuration.tracer.trace("evaluate", input: state.priority) do |_span|
    judge  = LocalLlmJudge.new(model: LLMConfig::MODEL)
    runner = Phronomy::Eval::Runner.new(scorer: judge)

    priority = state.priority || "security"

    review_dataset = Phronomy::Eval::Dataset.from_array([{
      input:    "Ruby code review for #{priority}:\n#{state.source_code[0, 400]}",
      expected: "specific code issues with severity levels and line references"
    }])
    review_score = runner.run(
      review_dataset,
      ->(_input) { state.reviews[priority.to_sym].to_s }
    ).first.score

    improve_dataset = Phronomy::Eval::Dataset.from_array([{
      input:    state.reviews[priority.to_sym].to_s,
      expected: "improved Ruby code in a ```ruby``` block addressing the identified issues"
    }])
    improve_score = runner.run(
      improve_dataset,
      ->(_input) { state.improved_code.to_s }
    ).first.score

    scores = {
      review_quality:      (review_score * 10).round(1),
      improvement_quality: (improve_score * 10).round(1)
    }
    [state.merge(eval_scores: scores), nil]
  end
end

# ---- Workflow assembly ----
def build_pipeline
  Phronomy::Workflow.define(ReviewState) do
    initial :load_and_split
    state :load_and_split,  action: LOAD_AND_SPLIT_NODE
    state :parallel_review, action: PARALLEL_REVIEW_NODE
    wait_state :awaiting_priority
    state :improve,  action: IMPROVE_NODE
    state :evaluate, action: EVALUATE_NODE

    transition from: :load_and_split,  to: :parallel_review
    transition from: :parallel_review, to: :awaiting_priority
    transition from: :improve,         to: :evaluate
    transition from: :evaluate,        to: :__finish__

    # User selects a review priority before the improver runs.
    transition from: :awaiting_priority, on: :proceed, to: :improve
  end
end
