#!/usr/bin/env python3
"""Extract conversation topics from all AI agents for a given date.

Scans Cursor, Codex, Claude Code transcripts and OpenClaw memory.
Each agent's collector is independent — missing agents are silently skipped.
Optionally filter to a specific workspace via WORKSPACE_DIR env var.
"""

import json
import os
import re
import sys
from datetime import datetime, timedelta
from pathlib import Path
from collections import defaultdict


def get_target_date():
    if len(sys.argv) > 1:
        return sys.argv[1]
    return datetime.now().strftime("%Y-%m-%d")


def _workspace_slug(workspace_dir):
    """Convert workspace path to Cursor's project directory slug."""
    if not workspace_dir:
        return None
    return workspace_dir.replace("/", "-").lstrip("-")


def extract_cursor_conversations(target_date, workspace_dir=None):
    """Read Cursor agent transcripts for a given date.

    If workspace_dir is set, only scan that workspace's transcripts.
    Otherwise scan all Cursor project transcript directories.
    """
    cursor_projects = Path.home() / ".cursor/projects"
    if not cursor_projects.exists():
        return []

    dt = datetime.strptime(target_date, "%Y-%m-%d")
    dt_start = dt.timestamp()
    dt_end = (dt + timedelta(days=1)).timestamp()

    project_dirs = []
    if workspace_dir:
        slug = _workspace_slug(workspace_dir)
        if slug:
            candidate = cursor_projects / slug
            if candidate.exists():
                project_dirs = [candidate]
    else:
        project_dirs = [d for d in cursor_projects.iterdir() if d.is_dir()]

    results = []
    for project_dir in project_dirs:
        transcripts_dir = project_dir / "agent-transcripts"
        if not transcripts_dir.exists():
            continue

        for uuid_dir in transcripts_dir.iterdir():
            if not uuid_dir.is_dir():
                continue
            mtime = uuid_dir.stat().st_mtime
            if not (dt_start <= mtime < dt_end):
                continue

            jsonl = uuid_dir / f"{uuid_dir.name}.jsonl"
            if not jsonl.exists():
                continue

            queries = []
            with open(jsonl) as f:
                for line in f:
                    try:
                        obj = json.loads(line.strip())
                        if obj.get("role") == "user":
                            content = obj.get("message", {}).get("content", [])
                            for c in content:
                                if c.get("type") == "text":
                                    text = c["text"]
                                    match = re.search(
                                        r"<user_query>\s*(.*?)\s*</user_query>",
                                        text,
                                        re.DOTALL,
                                    )
                                    if match:
                                        msg = match.group(1).strip()
                                        if len(msg) > 5 and not msg.startswith(
                                            "Implement the plan"
                                        ):
                                            queries.append(msg[:200])
                    except Exception:
                        pass

            if queries:
                ts = datetime.fromtimestamp(mtime).strftime("%H:%M")
                results.append({
                    "agent": "Cursor",
                    "time": ts,
                    "id": uuid_dir.name,
                    "queries": queries,
                })

    return sorted(results, key=lambda x: x["time"])


def extract_codex_conversations(target_date):
    """Read Codex session transcripts for a given date."""
    parts = target_date.split("-")
    sessions_dir = Path.home() / f".codex/sessions/{parts[0]}/{parts[1]}/{parts[2]}"
    if not sessions_dir.exists():
        return []

    results = []
    for f in sessions_dir.glob("rollout-*.jsonl"):
        queries = []
        with open(f) as fh:
            for line in fh:
                try:
                    obj = json.loads(line.strip())
                    msg_type = obj.get("type", "")
                    payload = obj.get("payload", {})
                    if not isinstance(payload, dict):
                        continue
                    if payload.get("role") == "user" and msg_type in (
                        "event_msg",
                        "response_item",
                    ):
                        content = payload.get("content", [])
                        if isinstance(content, list):
                            for c in content:
                                text = c.get("text") or c.get("input_text", "")
                                if (
                                    text
                                    and len(text) > 5
                                    and not text.startswith("#")
                                    and not text.startswith("<")
                                ):
                                    queries.append(text[:200])
                                    break
                        elif (
                            isinstance(content, str)
                            and len(content) > 5
                            and not content.startswith("<")
                        ):
                            queries.append(content[:200])
                except Exception:
                    pass

        if queries:
            ts_match = re.search(r"(\d{2})-(\d{2})-(\d{2})-", f.name)
            ts = f"{ts_match.group(1)}:{ts_match.group(2)}" if ts_match else "?"
            results.append({
                "agent": "Codex",
                "time": ts,
                "id": f.stem,
                "queries": queries,
            })

    return sorted(results, key=lambda x: x["time"])


def extract_claude_code_conversations(target_date):
    """Read Claude Code transcripts modified on a given date."""
    claude_dir = Path.home() / ".claude/projects"
    if not claude_dir.exists():
        return []

    dt = datetime.strptime(target_date, "%Y-%m-%d")
    dt_start = dt.timestamp()
    dt_end = (dt + timedelta(days=1)).timestamp()

    results = []
    for projects_dir in claude_dir.iterdir():
        if not projects_dir.is_dir():
            continue
        for f in projects_dir.glob("*.jsonl"):
            mtime = f.stat().st_mtime
            if not (dt_start <= mtime < dt_end):
                continue

            queries = []
            with open(f) as fh:
                for line in fh:
                    try:
                        obj = json.loads(line.strip())
                        if obj.get("type") == "user":
                            msg = obj.get("message", {})
                            content = msg.get("content", "")
                            if (
                                isinstance(content, str)
                                and len(content) > 5
                                and not content.startswith("<")
                            ):
                                queries.append(content[:200])
                            elif isinstance(content, list):
                                for c in content:
                                    if c.get("type") == "text" and len(
                                        c.get("text", "")
                                    ) > 5:
                                        queries.append(c["text"][:200])
                                        break
                    except Exception:
                        pass

            if queries:
                ts = datetime.fromtimestamp(mtime).strftime("%H:%M")
                results.append({
                    "agent": "Claude Code",
                    "time": ts,
                    "id": f.stem,
                    "queries": queries,
                })

    return sorted(results, key=lambda x: x["time"])


def extract_naomi_memory(target_date):
    """Read Naomi's daily memory file."""
    memory_file = Path.home() / f".openclaw/workspace/memory/{target_date}.md"
    if not memory_file.exists():
        return None
    return memory_file.read_text().strip()


def main():
    target_date = get_target_date()
    workspace_dir = os.environ.get("WORKSPACE_DIR")

    cursor = extract_cursor_conversations(target_date, workspace_dir)
    codex = extract_codex_conversations(target_date)
    claude = extract_claude_code_conversations(target_date)
    naomi = extract_naomi_memory(target_date)

    output = {
        "date": target_date,
        "conversations": cursor + codex + claude,
        "naomi_memory": naomi,
        "total_sessions": len(cursor) + len(codex) + len(claude),
    }

    print(json.dumps(output, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
