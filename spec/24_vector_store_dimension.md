# spec/24_vector_store_dimension.md

## Purpose

Demonstrate the embedding dimension validation guard added to
`Phronomy::VectorStore::InMemory` (and all VectorStore implementations) in
v0.5.4.

When an embedding's size does not match the store's expected dimension,
`ArgumentError` is raised immediately.  This prevents the silent vector
truncation that `Array#zip` would otherwise produce, which corrupts cosine
similarity scores.

No LLM or embedding model is required — the example uses hand-crafted
4-dimensional float vectors.

## Phronomy Features Demonstrated

- `Phronomy::VectorStore::InMemory.new(dimension: N)` — explicit dimension
  specified at construction time
- `ArgumentError` raised on `add` or `search` when embedding size mismatches
- Dimension inferred automatically from the first `add` call when `dimension:`
  is omitted
- `search` does not establish the dimension (read-only with respect to the schema)
- `clear` retains the established dimension (schema property, not document data)

## Expected Output (approximate)

```
=== 24 VectorStore Dimension Validation ===

[1] Creating store with explicit dimension: 4
    Adding 3 documents with matching 4-dimensional embeddings ... OK

[2] Attempting to add a 3-dimensional embedding (mismatch)
    ArgumentError: Embedding dimension mismatch: expected 4, got 3

[3] Attempting to search with a 3-dimensional query (mismatch)
    ArgumentError: Embedding dimension mismatch: expected 4, got 3

[4] Valid search — top 2 nearest neighbours
    1. [doc1] Ruby threads and concurrency (score: 1.0)
    2. [doc3] Ruby on Rails web development (score: ...)

[5] Dimension inferred from first add (no explicit dimension:)
    Inferred dimension: 2
    ArgumentError on second add: Embedding dimension mismatch: expected 2, got 3

[6] clear retains established dimension
    Added after clear: OK (dimension still 4)

Done.
```

## Implementation Steps

1. Create `Phronomy::VectorStore::InMemory.new(dimension: 4)`.
2. `add` three 4-dimensional documents.
3. Attempt `add` with a 3-dimensional embedding → rescue and print `ArgumentError`.
4. Attempt `search` with a 3-dimensional query → rescue and print `ArgumentError`.
5. Perform a valid `search` and print the top-2 results.
6. Create a second store without explicit dimension; add a 2-dimensional vector
   (dimension inferred), then attempt a 3-dimensional add → rescue and print.
7. Call `clear` on the first store, then `add` a valid 4-dimensional embedding to
   show that dimension is retained after `clear`.
