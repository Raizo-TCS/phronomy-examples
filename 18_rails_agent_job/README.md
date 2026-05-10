# 18 Rails AgentJob (ActionCable Streaming)

Demonstrates `Phronomy::Rails::AgentJob` in a real Rails 8 application.
Users submit a question; the agent runs in a background job (Solid Queue) and
pushes each token to the browser in real time via ActionCable.

## Purpose

Show the complete path from user input to streaming LLM output in a Rails app:

```
Browser → POST /chat/send → AgentStreamingJob.perform_later
                                    ↓
                         Phronomy::Rails::AgentJob#perform
                                    ↓
                         DemoAgent#stream (LLM tokens)
                                    ↓
                         ActionCable.server.broadcast("agent_<id>", payload)
                                    ↓
                         WebSocket → Browser (real-time token display)
```

## Phronomy Features

| Feature | Usage |
|---------|-------|
| `Phronomy::Rails::AgentJob` | Core library job — runs agent, broadcasts events |
| `{ type: "token" }` | Real-time content delta |
| `{ type: "done" }` | Final output with complete text |
| `{ type: "error" }` | Error broadcast without process crash |

## How to Run

```bash
cd 18_rails_agent_job
bundle install
bin/rails db:prepare
bin/rails server
# then open http://localhost:3000
```

> In development the `async` ActionCable adapter is used, so no Redis is needed.

## Files Added

| File | Description |
|------|-------------|
| `app/agents/demo_agent.rb` | Simple phronomy agent for the demo |
| `app/channels/agent_channel.rb` | Streams to `"agent_<session_id>"` |
| `app/jobs/agent_streaming_job.rb` | Thin wrapper around `AgentJob` |
| `app/controllers/chat_controller.rb` | `GET /` and `POST /chat/send` |
| `app/views/chat/index.html.erb` | Chat UI with WebSocket JS |
| `config/initializers/llm.rb` | RubyLLM configuration |
| `config/routes.rb` | Root, `/chat/send`, `/cable` |
