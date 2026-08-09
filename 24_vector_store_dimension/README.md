# 24 — VectorStore + Agent RAG

This example moves beyond a standalone vector-store correctness test and shows
the complete Phronomy retrieval boundary:

```text
documents
  → Embeddings adapter
    → VectorStore
      → Phronomy::Tools::VectorSearch
        → Agent tool call
          → grounded answer
```

## Part 1: storage guarantees

`VectorStore::InMemory` demonstrates:

- explicit vector dimensions;
- dimension inference from the first inserted embedding;
- rejection of mismatched vectors;
- metadata stored with each vector.

## Part 2: retrieval as an Agent capability

`Phronomy::Tools::VectorSearch.from_store` creates a configured Tool class from:

- a `VectorStore`;
- an `Embeddings::Base` implementation;
- retrieval parameters such as `k`;
- a tool name and description.

The example uses a deterministic local embedding adapter so the retrieval layer
does not require a separate embedding service. The final Agent answer uses the
normal configured LLM.

Production applications can replace the in-memory store/embedding adapter with
the supported persistent vector backends and real embedding adapters without
changing the Agent/tool boundary.
