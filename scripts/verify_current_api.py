#!/usr/bin/env python3
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
failures: list[str] = []


def fail(path: Path, message: str) -> None:
    failures.append(f"{path.relative_to(ROOT)}: {message}")


def ruby_files():
    for path in ROOT.rglob("*.rb"):
        if ".git" not in path.parts and "vendor" not in path.parts:
            yield path


for path in ruby_files():
    text = path.read_text(encoding="utf-8")
    if "Phronomy::Agent::Context::Capability::Base" in text:
        fail(path, "legacy Capability::Base spelling remains; use Phronomy::Tool::Base")
    if "Phronomy::Agent::Runner" in text:
        fail(path, "removed Agent::Runner namespace remains")
    if ".thread_id" in text:
        fail(path, "removed WorkflowContext#thread_id accessor remains")
    if re.search(r"\.signal\(\s*thread_id\s*:", text, re.S):
        fail(path, "Workflow#signal(thread_id:) remains")
    if re.search(r"\.set_graph_metadata\(\s*thread_id\s*:", text, re.S):
        fail(path, "set_graph_metadata(thread_id:) remains")
    if re.search(r"config\s*:\s*\{[^}]*\bthread_id\s*:", text, re.S):
        fail(path, "Workflow config thread_id remains")
    if re.search(r"config\s*:\s*\{[^}]*\bsession_id\s*:", text, re.S):
        fail(path, "generic Agent session_id config remains")
    if "on_tool_approval_required" in text:
        fail(path, "removed approval listener API remains")

    # High-signal per-operation listener patterns.
    # 21_team_coordinator uses TeamCoordinator#stream(&block) — a coordinator-specific
    # task-progress callback, not the Agent on_event SPI; skip the block check there.
    is_team_coordinator = "21_team_coordinator" in path.parts
    if re.search(
        r"\.(?:invoke|invoke_async|stream|stream_async)\s*\([^)]*\bon_event\s*:",
        text,
        re.S,
    ):
        fail(path, "per-operation on_event listener remains")
    if not is_team_coordinator and re.search(
        r"\.(?:invoke|invoke_async|stream|stream_async)\s*\([^)]*\)\s+do\s*\|event\|",
        text,
        re.S,
    ):
        fail(path, "per-operation event block remains")

for root_name in ["30_sqlite_persistence", "31_postgresql_persistence"]:
    lib = ROOT / root_name / "lib"
    for path in lib.rglob("*.rb"):
        text = path.read_text(encoding="utf-8")
        for stale in [
            "Codec.dump_domain",
            "Codec.load_agent_root",
            "Codec.load_journal_record",
            "Codec.load_execution",
            "Codec.dump_workflow",
            "Codec.load_workflow",
        ]:
            if stale in text:
                fail(path, f"backend-owned domain codec remains: {stale}")
    codec_files = list(lib.rglob("codec.rb"))
    for path in codec_files:
        text = path.read_text(encoding="utf-8")
        if "Phronomy::Persistence::DurableRecord" not in text:
            fail(path, "DurableRecord envelope codec is missing")

if failures:
    print("Current Phronomy API preflight FAILED", file=sys.stderr)
    for item in failures:
        print(f"  - {item}", file=sys.stderr)
    raise SystemExit(1)

print("Current Phronomy API preflight PASS")
