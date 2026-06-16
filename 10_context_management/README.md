# 10 Context Management

Demonstrates phronomy's context window management features. Sections 1–7 run
without any LLM API calls. Sections 8–12 use a live LLM via `ContextDemoAgent`
(an `Agent::Base` subclass).

## Purpose

Explore the full suite of tools for fitting conversation history into a model's
context window: token estimation, budget calculation, application-managed
history, in-memory vector search, context assembly, custom tokenizers, and
`build_context` overrides for trimming and compacting messages.

## Phronomy Features

| Section | Feature | Class / API |
|---------|---------|-------------|
| 1 | Token estimation | `Phronomy::LlmContextWindow::TokenEstimator` |
| 2 | Budget definition | `Phronomy::LlmContextWindow::TokenBudget` |
| 3 | Application-managed history | `config[:messages]` / `result[:messages]` |
| 4 | Limiting history size | Ruby `Array#last(n)` slice pattern |
| 5 | Cosine-similarity search | `Phronomy::VectorStore::InMemory` |
| 6 | Assembling context within budget | `Phronomy::LlmContextWindow::Assembler` |
| 7 | Custom tokenizer | `TokenEstimator.tokenizer=` |
| 8 | Assembler + LLM call | `Assembler` + `ContextDemoAgent` (`Agent::Base`) |
| 9 | Multi-turn conversation | `Agent::Base` + `config[:messages]` round-trip |
| 10 | Static knowledge caching | `static_knowledge` DSL + `ContextVersionCache` |
| 11 | Trim oldest message | `build_context` override + `trim_messages` |
| 12 | Compact messages to summary | `build_context` override + `compact_messages` |

## Section Descriptions

### 1. TokenEstimator
`Phronomy::LlmContextWindow::TokenEstimator.estimate(text)` returns a fast
heuristic token count (approximately `text.length / 4`). No LLM call is made.

### 2. TokenBudget
`Phronomy::LlmContextWindow::TokenBudget.new(context_window:, max_output_tokens:, overhead:)`
encapsulates the arithmetic for a model's context window. `effective_input_limit`
gives the number of tokens available for input after reserving output and overhead.

### 3. Application-managed conversation history
Phronomy does not maintain conversation state internally. The application owns
the message array and passes it via `config[:messages]`. After each `invoke`,
the updated history is returned in `result[:messages]`. The application must
save this array and pass it on the next call.

### 4. Limiting history size
To stay within a token budget, slice the history array before passing it:
`all_messages.last(10)`. This keeps only the most recent messages.

### 5. VectorStore::InMemory
`Phronomy::VectorStore::InMemory` stores documents with pre-computed embeddings
and retrieves the top-k nearest neighbours by cosine similarity.
`store.add(id:, embedding:, metadata:)` inserts a document; `store.search(query_embedding:, k:)`
returns ranked results with `:id`, `:score`, and `:metadata`.

### 6. Context::Assembler
`Phronomy::LlmContextWindow::Assembler.new(budget:)` builds a context payload
that fits within `budget.effective_input_limit`. Chain `add_instruction`,
`add_knowledge`, and `add_messages`, then call `build` to get a hash with
`:messages` trimmed to the newest entries that fit the budget.

### 7. Custom Tokenizer
`TokenEstimator.tokenizer = ->(text) { ... }` replaces the built-in heuristic
with any callable. Setting it back to `nil` restores the default.

### 8. Assembler + LLM
Combines sections 2 and 6 with a real LLM call. A 20-turn history far
exceeding the budget is assembled and trimmed by `Assembler`, then the
reduced message list is passed to `ContextDemoAgent#invoke`. Token usage
reported by the model is printed alongside the estimated count.

### 9. Multi-turn conversation via Agent
Shows the `config[:messages]` round-trip pattern over two turns using
`ContextDemoAgent`. After turn 1 the agent learns the user's name; turn 2
confirms the agent recalls it from the messages passed in.

### 10. static_knowledge DSL + ContextVersionCache
The `static_knowledge` DSL attaches a `StaticKnowledge` object to an agent
class. The system text derived from it is SHA-256 fingerprinted on first use;
subsequent invocations on the same instance hit the cache and skip rebuilding
the system text.

### 11. build_context + trim_messages
Overriding `build_context` in a subclass and calling `trim_messages(messages, keep: n)`
drops the oldest messages before they are sent to the model, keeping the
effective context lean without changing the stored history.

### 12. build_context + compact_messages
`compact_messages(messages, keep_tail: n) { |dropped| "Summary..." }` replaces
the dropped leading messages with a single summary string. This is the
recommended pattern for long-running conversations where token budget pressure
requires compaction.

## How to Run

```bash
bundle exec ruby 10_context_management/run.rb
```

## Expected Output (approximate)

```
=== Context Management Example ===

--- 1. TokenEstimator ---
"Hello, world!" => 3 tokens (estimated)

--- 2. TokenBudget (explicit values) ---
context_window:    8192
max_output_tokens: 1024
overhead:           200
effective_input:   6968

--- 3. config[:messages] — application-managed conversation history ---
Application-managed history: 4 messages
Newest message: [assistant] I don't have live weather data.

--- 4. Limiting history size (keep last N messages) ---
Total history:             40 messages
Passed to agent (last 10): 10 messages

--- 5. VectorStore::InMemory ---
Added 3 documents.
Top result for query [1.0, 0.0]: "A" with score 1.0

--- 6. Context::Assembler — fit history within a token budget ---
History provided:       20 messages
After budget trimming:  N messages (newest kept)

--- 7. Custom Tokenizer ---
Text: "Hello, world!"
  default heuristic (len/4): 3 tokens
  custom tokenizer (words):  2 tokens
  restored default:          3 tokens

--- 8. Context::Assembler + LLM ---
...
LLM response:   <one-sentence summary of phronomy>

--- 9. Agent + config[:messages] multi-turn conversation ---
Turn 1 response: ...
Turn 2 response: Your name is Alice.

--- 10. static_knowledge DSL + ContextVersionCache ---
Fingerprint unchanged: true  (system text re-used on 2nd call)

--- 11. build_context + trim_messages ---
Turn 2 response: turn 2
(build_context override drops the oldest message from the LLM view before each call)

--- 12. build_context + compact_messages ---
Response after compaction: after compaction
(build_context override replaced the oldest message with a summary before the LLM call)

=== Done ===
```
