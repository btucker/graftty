#!/usr/bin/env python3
"""Inventory local harness transcript formats without exporting conversation text.

Counts include replayed records, subagents, and quoted examples. Tag counts are
candidate messages, not proof that every occurrence is a live harness envelope.
"""

import argparse
from collections import Counter
from contextlib import contextmanager
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import shutil
import subprocess


TAG = re.compile(r"(?m)^\s*<([A-Za-z][\w-]*)(?=[\s>])")


@contextmanager
def lines(path):
    if path.suffix != ".zst":
        with path.open(errors="replace") as stream:
            yield stream
        return
    if shutil.which("zstd") is None:
        raise SystemExit("zstd is required to inspect archived Codex sessions")
    with subprocess.Popen(["zstd", "-dc", str(path)], stdout=subprocess.PIPE,
                          text=True, errors="replace") as process:
        yield process.stdout
    if process.returncode:
        raise SystemExit(f"Could not decompress {path.name}")


def scan(provider, roots):
    files = sorted({p for root in roots if root.exists()
                    for pattern in ["*.jsonl", "*.jsonl.zst"] for p in root.rglob(pattern)})
    tags, tag_files, blocks, tools, markers, roles = Counter(), Counter(), Counter(), Counter(), Counter(), Counter()
    invalid = 0
    for path in files:
        file_tags = set()
        pending_questions = set()
        with lines(path) as stream:
            for line in stream:
                try:
                    record = json.loads(line)
                except (ValueError, TypeError):
                    invalid += 1
                    continue
                if not isinstance(record, dict):
                    continue
                if provider == "codex":
                    payload = record.get("payload", {})
                    if record.get("type") != "response_item" or not isinstance(payload, dict):
                        continue
                    if payload.get("type") in ["function_call", "custom_tool_call"]:
                        name = payload.get("name", "")
                        tools[name] += 1
                        if name in ["request_user_input", "functions.request_user_input"]:
                            pending_questions.add(payload.get("call_id"))
                    if payload.get("type") == "function_call_output" and payload.get("call_id") in pending_questions:
                        markers["synchronousQuestionResult"] += 1
                        pending_questions.remove(payload.get("call_id"))
                    if payload.get("type") != "message":
                        continue
                    message = payload
                else:
                    if record.get("type") not in ["user", "assistant"]:
                        continue
                    message = record.get("message", {})
                if not isinstance(message, dict):
                    continue
                role = message.get("role")
                roles[role] += 1
                content = message.get("content", [])
                if isinstance(content, str):
                    content = [{"type": "text", "text": content}]
                if not isinstance(content, list):
                    continue
                found = set()
                for block in content:
                    if not isinstance(block, dict):
                        continue
                    blocks[f"{role}:{block.get('type')}"] += 1
                    if block.get("type") == "tool_use":
                        tools[block.get("name", "")] += 1
                    if role != "user" or not isinstance(block.get("text"), str):
                        continue
                    text = block["text"]
                    found.update(TAG.findall(text))
                    if text.startswith("This session is being continued"):
                        markers["continuationSummary"] += 1
                    if text.startswith("[Request interrupted"):
                        markers["interruption"] += 1
                tags.update(found)
                file_tags.update(found)
                result = record.get("toolUseResult")
                if role == "user" and isinstance(result, dict) and "questions" in result and "answers" in result:
                    markers["structuredQuestionResult"] += 1
        tag_files.update(file_tags)
    return {"files": len(files), "compressedFiles": sum(p.suffix == ".zst" for p in files),
            "bytes": sum(p.stat().st_size for p in files), "roles": roles, "blocks": blocks,
            "tools": tools, "candidateTags": tags, "tagFiles": tag_files,
            "markers": markers, "invalidRecords": invalid}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex-home", type=Path, default=Path.home() / ".codex")
    parser.add_argument("--claude-home", type=Path, default=Path.home() / ".claude")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    report = {"capturedAt": datetime.now(timezone.utc).isoformat(),
              "codex": scan("codex", [args.codex_home / "sessions", args.codex_home / "archived_sessions"]),
              "claude": scan("claude", [args.claude_home / "projects"])}
    text = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.write_text(text)
    else:
        print(text, end="")


if __name__ == "__main__":
    main()
