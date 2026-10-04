# r8 unit 6: LLM / Tool contract migration

Use the core unit 6 checkout via PHRONOMY_PATH and update bundles with
`scripts/update_phronomy.sh`. Run `scripts/verify_offline.sh`; the root suite now
includes the local backend / explicit Tool schema example in `33_llm_tool_contracts`.
No database schema or unit 4 migration script changes are included.

The five root LLM value/failure constants move under `Phronomy::LLMAdapter`.
The code-review example now rescues those domain-owned failures. Preflight rejects
old root names. Custom adapters implement protected perform_complete/perform_stream
and return Request/Response/Message/StreamChunk values rather than SDK Chat objects.

Tool::Base no longer inherits RubyLLM::Tool. Both parameter declaration paths
validate the advertised schema. Before rollout, finish/resolve pending executions
on the old core when their saved Tool definitions differ from the new definitions;
the strict recovery comparison is retained. Existing quiescent journal history
remains readable. See core `docs/migrations/r8-unit6.md` for supported schemas,
removed SDK-derived methods and exact cancellation/compatibility boundaries.
