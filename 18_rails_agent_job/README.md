# 18 — Rails ActiveJob + Phronomy Agent streaming

This example shows how to integrate Phronomy with Rails **without requiring a
Phronomy-specific job abstraction**.

The boundary is deliberately application-owned:

```text
HTTP request
  → ActiveJob
    → DemoAgent#stream
      → StreamEvent
        → ActionCable broadcast
          → browser
```

`AgentStreamingJob` consumes the public `Agent#stream` API and translates
Phronomy events (`:token`, `:tool_call`, `:tool_result`, `:done`, `:error`) into
the application's ActionCable protocol.

This keeps responsibilities separated:

- Phronomy owns Agent execution and structured streaming events.
- Rails owns job persistence/retries and websocket delivery.
- the application owns the mapping between the two.

The job's `perform` signature matches the controller's keyword call:

```ruby
AgentStreamingJob.perform_later(
  "DemoAgent",
  input,
  stream: stream_name
)
```

Run the Rails application normally and open the chat page. The response is
streamed token-by-token through ActionCable.
