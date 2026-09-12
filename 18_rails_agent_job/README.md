# 18 — Rails ActiveJob integration: basic and streaming examples

This application contains two runnable examples using the same chat page and
Action Cable channel. Select **Final answer only** or **While generating** in the
page. The latter remains the default.

| Role | Complete source | Purpose |
|---|---|---|
| Basic | [AgentResultJob](app/jobs/agent_result_job.rb) | Invoke an Agent from ActiveJob and publish its final result |
| Feature-rich | [AgentStreamingJob](app/jobs/agent_streaming_job.rb) and [OrderedEventDelivery](app/services/ordered_event_delivery.rb) | Publish intermediate events with local ordering, buffering and explicit failure handling |

## Basic path

The HTTP controller queues AgentResultJob. The Job invokes DemoAgent and waits
on the Rails Job thread. It then broadcasts the final result on that same
thread. There is no listener running on Phronomy's EventLoop and no application
delivery queue. This is the complete integration when intermediate progress is
not part of the display requirement.

Phronomy owns Agent execution; ActiveJob owns Job execution/retry configuration;
the application chooses the Agent, the Action Cable stream and payload, and its
failure handling. The sample reports an error to the channel where possible and
re-raises the original exception for the Job backend. Broadcast success does not
prove browser receipt.

## Streaming path

AgentStreamingJob registers a listener when constructing the Agent, then calls
stream. That listener runs on Phronomy's EventLoop even though the Job called
stream from its own thread. It only creates plain payloads and calls publish.
OrderedEventDelivery sends those payloads from the existing Phronomy OffloadPool
via Blocking.call_async. The Rails-facing work runs inside the Rails executor.

| Required property or selected policy | This example |
|---|---|
| Required runtime boundary | Never wait for network I/O, a Task, or queue space on EventLoop |
| Display ordering | Serial broadcast calls in one adapter's acceptance order |
| Buffer implementation | Process-local queue, copied plain payloads |
| Resource setting | Up to 256 queued payloads, plus the batch currently being sent |
| Selected optimization | Take up to 32 queued payloads at a time and combine adjacent token payloads with matching metadata |
| Overload | Reject publish, stop accepting new events, and retain the error for the Job's final flush |
| Completion | After stream returns/raises, wait up to 30 seconds on the Job thread for remaining delivery work |
| Failure | Preserve the original Agent error, otherwise propagate delivery failure as Job failure |

Changing these options is an application decision. The notification queue capacity
is separate from the Runtime's worker count and offload queue capacity. Payload
count does not bound total bytes. No worker waits on an empty notification queue;
under sustained input, the draining worker can remain occupied. I/O timeouts belong
in the chosen Action Cable backend. The flush timeout stops waiting, not network I/O.

If Agent construction or execution raises before an error event was accepted, the
Job attempts to enqueue an error notification. If delivery itself has failed, that
attempt is logged and the original error remains authoritative. Queue overflow or
invalid publication stops acceptance, lets accepted work drain, and fails the final
flush even if the event source only logs the listener exception. A worker admission
or broadcast failure clears the remaining queue and fails the Job. This does not
guarantee that all notifications were sent. Retries are an application/Job
backend policy and can repeat external effects or notifications.

Ordering applies only within one adapter, not across Jobs, processes or concurrent
user requests. close_and_wait observes local broadcast processing, not browser
receipt or rendering. There is no persisted outbox, ACK, replay, or exactly-once
delivery. Agent semantic durability remains independent from notifications.

## Run and compare

Use the framework checkout containing Task.completed/failed and Blocking.call_async
via the shared PHRONOMY_PATH setting until a release containing them is selected.
Run the Rails app normally, open the chat page and compare its two display modes.
Both jobs use the same allowlist and keyword `stream:` as the controller.

For a small Task-to-Workflow example, see [03_state_graph](../03_state_graph/README.md).
For synchronous external work and explicit completion signals, see
[25_event_loop](../25_event_loop/README.md). These are complementary examples, not
requirements to copy the streaming adapter into every application.