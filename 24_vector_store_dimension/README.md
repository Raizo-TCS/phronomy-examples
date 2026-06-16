# 24 VectorStore Dimension Validation

## Purpose

Demonstrates the embedding dimension guard introduced in phronomy v0.5.4.
All `VectorStore` implementations now validate that every embedding vector
matches the store's expected dimension on both `add` and `search`.
When a mismatch is detected, `ArgumentError` is raised immediately instead of
silently truncating the vector (which would corrupt cosine similarity scores).

No LLM or embedding model is required — all embeddings are hand-crafted
4-dimensional (or 2-dimensional) float arrays.

## Phronomy Features

| Feature | Class / API |
|---|---|
| In-memory vector store | `Phronomy::VectorStore::InMemory` |
| Explicit dimension on construction | `InMemory.new(dimension: 4)` |
| Dimension inferred from first insert | `InMemory.new` (no `dimension:`) |
| Document insertion | `store.add(id:, embedding:, metadata:)` |
| Nearest-neighbour search | `store.search(query_embedding:, k:)` |
| Store reset | `store.clear` |

## How to Run

```bash
cd /path/to/phronomy-examples
export PATH="$HOME/.local/share/gem/ruby/3.2.0/bin:$PATH"
bundle exec ruby 24_vector_store_dimension/run.rb
```

No running LLM server is needed.

## Expected Output (approximate)

```
=== 24 VectorStore Dimension Validation ===

[1] Creating store with explicit dimension: 4
    Adding 3 documents with matching 4-dimensional embeddings...
    OK

[2] Attempting to add a 3-dimensional embedding (mismatch)
    ArgumentError: embedding dimension mismatch: expected 4, got 3

[3] Attempting to search with a 3-dimensional query (mismatch)
    ArgumentError: embedding dimension mismatch: expected 4, got 3

[4] Valid search — top 2 nearest neighbours

    1. [doc1] Ruby threads and concurrency (score: 1.0)
    2. [doc3] Ruby on Rails web development (score: ~0.9999)

[5] Dimension inferred from first add (no explicit dimension:)

    Inferred dimension: 2
    ArgumentError on second add: embedding dimension mismatch: expected 2, got 3

[6] clear retains established dimension

    Added 4-dimensional embedding after clear: OK

Done.
```

Scores for the nearest-neighbour results will be exact cosine similarity
values and may differ slightly from the values shown above.
