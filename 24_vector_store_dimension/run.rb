# frozen_string_literal: true

# 24 VectorStore Dimension Validation
#
# Demonstrates the embedding dimension guard added to all VectorStore
# implementations in v0.5.4. When an embedding's size does not match the
# expected dimension, ArgumentError is raised immediately rather than silently
# truncating the vector (which would corrupt cosine similarity scores).
#
# No LLM or embedding model is required — this example uses hand-crafted
# 4-dimensional float vectors.

require_relative "../shared/llm_config"
require "phronomy"

puts "=== 24 VectorStore Dimension Validation ===\n\n"

# ── [1] Explicit dimension ───────────────────────────────────────────────────
puts "[1] Creating store with explicit dimension: 4"
puts "    Adding 3 documents with matching 4-dimensional embeddings..."

store = Phronomy::Agent::Context::Knowledge::VectorStore::InMemory.new(dimension: 4)

store.add(id: "doc1", embedding: [0.90, 0.10, 0.00, 0.00],
          metadata: {text: "Ruby threads and concurrency"})
store.add(id: "doc2", embedding: [0.00, 0.00, 0.90, 0.10],
          metadata: {text: "Machine learning in Ruby"})
store.add(id: "doc3", embedding: [0.50, 0.50, 0.00, 0.00],
          metadata: {text: "Ruby on Rails web development"})

puts "    OK\n\n"

# ── [2] Mismatch on add ──────────────────────────────────────────────────────
puts "[2] Attempting to add a 3-dimensional embedding (mismatch)"

begin
  store.add(id: "bad", embedding: [0.1, 0.2, 0.3],
            metadata: {text: "wrong dimension"})
rescue ArgumentError => e
  puts "    ArgumentError: #{e.message}\n\n"
end

# ── [3] Mismatch on search ───────────────────────────────────────────────────
puts "[3] Attempting to search with a 3-dimensional query (mismatch)"

begin
  store.search(query_embedding: [0.9, 0.1, 0.0], k: 2)
rescue ArgumentError => e
  puts "    ArgumentError: #{e.message}\n\n"
end

# ── [4] Valid search ─────────────────────────────────────────────────────────
puts "[4] Valid search — top 2 nearest neighbours\n\n"

results = store.search(query_embedding: [0.90, 0.10, 0.00, 0.00], k: 2)

results.each_with_index do |r, i|
  puts "    #{i + 1}. [#{r[:id]}] #{r[:metadata][:text]} (score: #{r[:score].round(4)})"
end

puts

# ── [5] Inferred dimension ───────────────────────────────────────────────────
puts "[5] Dimension inferred from first add (no explicit dimension:)\n\n"

store2 = Phronomy::Agent::Context::Knowledge::VectorStore::InMemory.new
store2.add(id: "a", embedding: [0.7, 0.7], metadata: {text: "two-dim doc"})

puts "    Inferred dimension: 2"

begin
  store2.add(id: "b", embedding: [0.1, 0.2, 0.3], metadata: {text: "wrong"})
rescue ArgumentError => e
  puts "    ArgumentError on second add: #{e.message}\n\n"
end

# ── [6] clear retains dimension ──────────────────────────────────────────────
puts "[6] clear retains established dimension\n\n"

store.clear
store.add(id: "after_clear", embedding: [0.1, 0.2, 0.3, 0.4],
          metadata: {text: "added after clear"})

puts "    Added 4-dimensional embedding after clear: OK\n\n"

puts "Done."
