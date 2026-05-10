# 04 Interrupt / Resume

Demonstrates the human-in-the-loop pattern with `interrupt_before` and `resume`.

## Purpose

Show how to pause a graph before a critical node, present the intermediate
result to a human for approval, and then resume or abandon execution.

## Phronomy Features

| Feature | Usage |
|---------|-------|
| `CompiledGraph#interrupt_before(node) { \|state\| :halt }` | Registers a pre-node callback that halts execution |
| `State#halted_before` / `State#current_nodes` | Halt metadata carried in state |
| `CompiledGraph#resume(state:)` | Resumes from the halted state |

## Flow

```
START → :draft → [interrupt_before :send] → :send → FINISH
                       ↑ halts here; human approves or cancels
```

1. `invoke` runs `:draft` and halts before `:send`, returning the paused state.
2. The program displays the draft and prompts `[yes/no]`.
3. On "yes": `resume(state:)` runs `:send` and finishes.
4. On "no": execution is abandoned.

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
