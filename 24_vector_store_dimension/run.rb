#!/usr/bin/env ruby
# frozen_string_literal: true

# 24 VectorStore + Agent RAG
#
# Part 1 demonstrates VectorStore dimension guarantees.
# Part 2 wires the store into Phronomy::Tools::VectorSearch and exposes semantic
# retrieval to an Agent as a normal capability.
#
# A deterministic local embedding adapter keeps the retrieval layer
# self-contained; only the final Agent call requires the configured LLM.

require_relative "../shared/llm_config"
require_relative "../shared/output_validator"
require "phronomy"

puts "=== 24 VectorStore + Agent RAG ==="
puts

puts "--- Part 1: dimension validation ---"

store = Phronomy::VectorStore::InMemory.new(dimension: 4)
store.add(
  id: "dimension-demo",
  embedding: [1.0, 0.0, 0.0, 0.0],
  metadata: {content: "dimension demo"}
)

puts "Explicit dimension configured: 4"
puts "Size:               #{store.size}"

begin
  store.add(
    id: "bad",
    embedding: [1.0, 0.0, 0.0],
    metadata: {content: "wrong dimension"}
  )
rescue ArgumentError => e
  puts "Mismatched add rejected: #{e.message}"
end

inferred = Phronomy::VectorStore::InMemory.new
inferred.add(
  id: "first",
  embedding: [0.0, 1.0, 0.0, 0.0],
  metadata: {content: "first document"}
)
puts "Inferred dimension from first add: 4"
puts

puts "--- Part 2: VectorSearch tool → Agent ---"

class KeywordEmbeddings < Phronomy::VectorStore::Embeddings::Base
  TERMS = %w[refund shipping support security].freeze

  def embed(text, cancellation_token = nil)
    cancellation_token&.raise_if_cancelled!

    normalized = text.to_s.downcase
    vector = TERMS.map { |term| normalized.scan(term).length.to_f }

    # Give otherwise-empty queries a stable non-zero vector.
    vector[3] = 0.1 if vector.all?(&:zero?)

    magnitude = Math.sqrt(vector.sum { |value| value * value })
    vector.map { |value| value / magnitude }
  end
end

embeddings = KeywordEmbeddings.new
knowledge_store = Phronomy::VectorStore::InMemory.new(dimension: 4)

documents = {
  "refund" => "Refund policy: unopened products can be returned within 30 days.",
  "shipping" => "Shipping policy: standard delivery normally takes 3-5 business days.",
  "support" => "Support contact: support@example.test.",
  "security" => "Security incidents must be escalated to the on-call security engineer."
}

documents.each do |id, content|
  knowledge_store.add(
    id: id,
    embedding: embeddings.embed(content),
    metadata: {content: content, source: "#{id}.md"}
  )
end

search_tool = Phronomy::Tools::VectorSearch.from_store(
  knowledge_store,
  embeddings: embeddings,
  k: 2,
  tool_name: "search_knowledge",
  description: "Search the company knowledge base before answering policy questions."
)

Object.const_set(:Example24SearchKnowledgeTool, search_tool)

class RagAgent < Phronomy::Agent::Base
  agent_definition id: "example-24-rag-agent", version: 1

  model LLMConfig::MODEL
  provider LLMConfig::PROVIDER
  instructions <<~PROMPT
    Answer company policy questions only after calling search_knowledge.
    Ground the answer in the retrieved text and do not invent policy.
  PROMPT

  tools(Example24SearchKnowledgeTool => nil)
end

question = "How long does standard shipping take?"
events = []

result = OutputValidator.validate(
  "RAG agent returns the shipping policy",
  check: ->(r) {
    r[:output].to_s.include?("3") &&
      events.any? { |event|
        event.type == :tool_call &&
          event.payload[:tool_call]&.name == "search_knowledge"
      }
  }
) do
  rag_agent = RagAgent.new(on_event: ->(event) { events << event })
  rag_agent.invoke(question)
end

retrieval_calls = events.count do |event|
  event.type == :tool_call &&
    event.payload[:tool_call]&.name == "search_knowledge"
end

puts "Question: #{question}"
puts "Answer:   #{result[:output]}"
puts "Retrieved through #{retrieval_calls} VectorSearch call(s)."
puts "Execution: #{result[:execution_id]}"
