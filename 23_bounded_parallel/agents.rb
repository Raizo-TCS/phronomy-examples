# frozen_string_literal: true

# Agents for example 23 — Bounded Parallel Dispatch.

# Classifies the sentiment of a product review as POSITIVE, NEGATIVE, or NEUTRAL.
class SentimentAgent < Phronomy::Agent::Base
  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  instructions <<~INST
    Classify the sentiment of the given product review as POSITIVE, NEGATIVE,
    or NEUTRAL. Respond with just the label and a brief reason separated by
    " — ", e.g.: "POSITIVE — customer loved the fast shipping and quality."
    Keep the reason under 15 words.
  INST
end

# Extracts the three most important keywords from a short text.
class KeywordExtractor < Phronomy::Agent::Base
  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  instructions <<~INST
    Extract the 3 most important keywords from the given product review.
    Respond with a comma-separated list only, e.g.: "quality, shipping, price"
  INST
end

# Orchestrator that coordinates parallel review analysis.
class ReviewOrchestrator < Phronomy::Agent::Orchestrator
  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  instructions "Coordinate product-review analysis tasks."

  # Fan-out: run SentimentAgent on every review with at most 3 concurrent threads.
  # on_error: :skip means a failed slot returns nil; the batch continues.
  def analyze_sentiments(reviews)
    fan_out(
      agent: SentimentAgent,
      inputs: reviews,
      max_concurrency: 3,
      on_error: :skip
    )
  end

  # dispatch_parallel: heterogeneous agents on two different reviews.
  # Cap at 2 concurrent threads; skip individual failures.
  def mixed_analysis(reviews)
    dispatch_parallel(
      {agent: SentimentAgent, input: reviews[0]},
      {agent: KeywordExtractor, input: reviews[1]},
      max_concurrency: 2,
      on_error: :skip
    )
  end
end
