# 04 Interrupt / Resume

Demonstrates the human-in-the-loop (HITL) pattern using `wait_state` and
`send_event`. A workflow generates an email draft, pauses at a wait state for
human approval, and then either completes or is abandoned.

## Purpose

Show how to pause a workflow at a named wait state, present the intermediate
result to a human, and resume execution by sending an event — or abandon it
entirely.

## Phronomy Features

| Feature | Usage |
|---------|-------|
| `wait_state :awaiting_approval` | Declares a pause point in the Workflow DSL |
| `Workflow#invoke` | Runs the workflow and returns the paused `MailState` |
| `Workflow#send_event(state:, event:)` | Resumes the workflow from the paused state |
| `Phronomy::Agent::Base` subclass (`DraftAgent`) | LLM-backed agent that writes the email draft |
| `Phronomy::WorkflowContext` (`MailState`) | Typed state container shared across nodes |

## State Class

```ruby
class MailState
  include Phronomy::WorkflowContext

  field :topic,    type: :replace, default: ""
  field :draft,    type: :replace, default: ""
  field :approved, type: :replace, default: false
end
```

## Agent

```ruby
class DraftAgent < Phronomy::Agent::Base
  model        LLMConfig::MODEL
  provider     LLMConfig::PROVIDER
  instructions "You are a business email expert. Write a polite email including subject and body."
end
```

## Workflow Definition

```ruby
app = Phronomy::Workflow.define(MailState) do
  initial :draft
  state :draft, action: DRAFT_NODE
  wait_state :awaiting_approval
  state :send, action: SEND_NODE

  transition from: :draft, to: :awaiting_approval
  transition from: :send,  to: :__finish__

  transition from: :awaiting_approval, on: :approve, to: :send
end
```

## Flow

```
START → :draft → :awaiting_approval → (paused; human approves)
                                           ↓ :approve event
                                        :send → FINISH
```

1. `app.invoke({topic: topic})` runs `:draft` (calls `DraftAgent`) and pauses
   at `:awaiting_approval`, returning the current `MailState`.
2. The program displays the draft and prompts `[yes/no]`.
3. On "yes": `app.send_event(state: state, event: :approve)` transitions to
   `:send`, prints a confirmation, and finishes.
4. On "no": execution is abandoned and nothing is sent.

## How to Run

```bash
bundle exec ruby 04_interrupt_resume/run.rb
```

## Expected Output (approximate)

```
=== Interrupt / Resume Example ===
Topic: Project completion report

[DRAFT GENERATED]
Subject: Project Completion Notice
...

Approve and send? [yes/no]: yes

[SENT] Email sent successfully.
```
