# 20 CVE Scanner

Rails-based CVE analysis example using Phronomy Workflow and Agents.

## Current execution model

The scan is coordinated by a Workflow FSMSession on Phronomy's EventLoop.
Long-running work is split by responsibility:

```text
Workflow EventLoop / FSMSession
  ├─ Agent reasoning
  │    └─ Agent#stream_async → completion Task → Workflow#signal
  │
  └─ unavoidable blocking application I/O
       ├─ shell commands
       └─ Ubuntu CVE scraper
            ↓
       Runtime#blocking_io (bounded BlockingAdapterPool)
            ↓ on_complete
       Workflow#signal
```

The application does not create raw Threads for Workflow orchestration and does
not place logical waits for child Agents into the blocking-I/O pool.

## Main Phronomy features

- `Phronomy::Workflow.define`
- `Workflow#signal`
- Agent `stream_async`
- `Phronomy::Task` completion handles
- `Runtime#blocking_io`
- Tool approval / operator wait states
- follow-up and remediation loops represented as FSM state

## Development

From this directory:

```bash
bundle install
bin/rails db:create db:migrate
bin/rails server
```

For repository-wide verification, use the root scripts:

```bash
export PHRONOMY_PATH=../phronomy
./scripts/update_phronomy.sh
./scripts/verify_examples.sh
```

The verification suite starts this Rails app with `CVE_SCANNER_MOCK_LLM=1` so
GUI smoke tests do not require a live model server.
