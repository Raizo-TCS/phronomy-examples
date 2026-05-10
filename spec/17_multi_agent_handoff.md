# Spec: 17_multi_agent_handoff

## Purpose

Demonstrate `Phronomy::Agent::Runner` for hub-and-spoke multi-agent routing:
a triage agent receives all user queries and automatically transfers them to the
appropriate specialist agent via a tool call.

## Phronomy Features Demonstrated

| Feature | Usage |
|---------|-------|
| `Phronomy::Agent::Runner` | Orchestrates conversation routing between agents |
| `routes:` configuration | Declares which agents may hand off to which targets |
| `result[:agent]` | Reports which agent produced the final response |
| Handoff tools (auto-generated) | `transfer_to_billing_agent`, `transfer_to_tech_support_agent` |
| `HandoffError` | Raised when `MAX_HANDOFFS` is exceeded |

## Expected Output (approximate)

```
=== 17 Multi-Agent Handoff ===

--- Scenario 1: Billing query ---
User: "I was charged twice on my last invoice."
→ Handled by: BillingAgent
Response: <billing-related answer>

--- Scenario 2: Technical query ---
User: "My app keeps crashing with a nil pointer error."
→ Handled by: TechSupportAgent
Response: <technical answer>

--- Scenario 3: General query (stays at triage) ---
User: "What are your business hours?"
→ Handled by: TriageAgent
Response: <general answer>

Done.
```

## Implementation Steps

1. Create `spec/17_multi_agent_handoff.md` (this file)
2. Create `17_multi_agent_handoff/agents.rb`:
   - `TriageAgent` — receives queries, uses handoff tools
   - `BillingAgent` — billing/payment specialist
   - `TechSupportAgent` — technical issue specialist
3. Create `17_multi_agent_handoff/run.rb`:
   - Instantiate agents and Runner with hub-and-spoke routes
   - Run 3 scenarios; print which agent responded
4. Create `17_multi_agent_handoff/README.md`
