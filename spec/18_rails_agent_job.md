# Spec: 18_rails_agent_job

## Purpose

Demonstrate `Phronomy::Rails::AgentJob` in a real Rails application: users
type a message, the job runs the agent in a background worker, and each token
is pushed to the browser in real time via ActionCable.

## Phronomy Features Demonstrated

| Feature | Usage |
|---------|-------|
| `Phronomy::Rails::AgentJob` | Runs agent in background, broadcasts to ActionCable |
| `AgentJob.perform_later` (via wrapper) | Async background execution |
| ActionCable `agent_<session_id>` stream | Per-session WebSocket channel |
| `{ type: "token" }` broadcasts | Real-time token streaming |
| `{ type: "done" }` broadcast | Final output signal |
| `{ type: "error" }` broadcast | Error handling without re-raise |

## Expected Behaviour

1. User visits `/` — chat UI loads, WebSocket connects to `/cable`
2. User submits a message — `POST /chat/send` returns 202 immediately
3. Background job starts `DemoAgent#stream`, tokens flow via ActionCable
4. Browser appends each token to the UI; shows "Done." on completion
5. If the agent raises, an error message is displayed without crashing

## Implementation Steps

1. Create `spec/18_rails_agent_job.md` (this file)
2. Run `rails new` to generate minimal Rails skeleton
3. Add `phronomy` to Gemfile
4. Add `app/channels/agent_channel.rb` subscribing to `"agent_<session_id>"`
5. Add `app/agents/demo_agent.rb` using shared LLM config
6. Add `app/jobs/agent_streaming_job.rb` delegating to `Phronomy::Rails::AgentJob`
7. Add `app/controllers/chat_controller.rb` (GET `/`, POST `/chat/send`)
8. Add `app/views/chat/index.html.erb` with WebSocket JS
9. Update `config/routes.rb`
10. Add `config/initializers/llm.rb` for RubyLLM configuration
11. Create `README.md`
