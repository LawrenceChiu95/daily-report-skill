#!/usr/bin/env python3
"""Collect GitLab activity for a given date via GitLab API v4.

Reads GITLAB_HOST and GITLAB_TOKEN from environment variables.
Usage: GITLAB_HOST=https://git.tapsvc.com GITLAB_TOKEN=xxx python3 collect-gitlab.py [YYYY-MM-DD]
"""

import json
import os
import sys
from datetime import datetime, timedelta
from urllib.request import urlopen, Request
from urllib.parse import urlencode
from urllib.error import URLError, HTTPError


def api_get(host, token, path, params=None):
    url = f"{host}/api/v4{path}"
    if params:
        url += "?" + urlencode(params)
    req = Request(url, headers={
        "PRIVATE-TOKEN": token,
        "Accept": "application/json",
    })
    try:
        with urlopen(req, timeout=15) as resp:
            return json.loads(resp.read().decode())
    except Exception:
        return None


_project_cache = {}


def project_name(host, token, pid):
    """Return short project name (last path segment) for a given project id."""
    if pid in _project_cache:
        return _project_cache[pid]
    p = api_get(host, token, f"/projects/{pid}", {"simple": "true"})
    if p and isinstance(p, dict):
        name = p.get("path_with_namespace", str(pid))
        name = name.split("/")[-1]
    else:
        name = str(pid)
    _project_cache[pid] = name
    return name


def to_cst(iso_str):
    """Parse ISO UTC string → (CST datetime, 'HH:MM'). Returns (None, '') on failure."""
    if not iso_str:
        return None, ""
    try:
        s = iso_str.replace("Z", "")
        if "+" in s:
            s = s[: s.index("+")]
        dt = datetime.fromisoformat(s) + timedelta(hours=8)
        return dt, dt.strftime("%H:%M")
    except Exception:
        return None, ""


def collect(host, token, date):
    host = host.rstrip("/")
    dt = datetime.strptime(date, "%Y-%m-%d")

    # Use a wider window (±1 day) to account for UTC vs CST offset,
    # then filter precisely by CST date below.
    events = api_get(host, token, "/events", {
        "after": (dt - timedelta(days=1)).strftime("%Y-%m-%d"),
        "before": (dt + timedelta(days=2)).strftime("%Y-%m-%d"),
        "per_page": 100,
    })

    if not isinstance(events, list):
        return {
            "date": date,
            "commits": [], "mrs_authored": [], "mrs_reviewed": [],
            "commit_count": 0, "mr_count": 0, "review_count": 0,
            "error": "API 请求失败（token 无效或网络不通）",
        }

    commits, mrs_authored, mrs_reviewed = [], [], []

    for ev in events:
        dt_cst, t = to_cst(ev.get("created_at", ""))
        if not dt_cst or dt_cst.strftime("%Y-%m-%d") != date:
            continue

        action = ev.get("action_name", "")
        ttype = ev.get("target_type", "")
        pid = ev.get("project_id")

        # ── Push events (commits) ──────────────────────────────────────
        if action in ("pushed to", "pushed new") and ev.get("push_data"):
            pd = ev["push_data"]
            commits.append({
                "project": project_name(host, token, pid) if pid else "",
                "ref": pd.get("ref", ""),
                "commit_count": pd.get("commit_count", 1),
                "commit_title": pd.get("commit_title", ""),
                "time": t,
            })

        # ── MR events ─────────────────────────────────────────────────
        elif ttype == "MergeRequest":
            entry = {
                "action": action,
                "title": ev.get("target_title", ""),
                "project": project_name(host, token, pid) if pid else "",
                "time": t,
            }
            if action in ("opened", "created", "merged", "closed", "accepted"):
                mrs_authored.append(entry)
            elif action in ("commented on", "approved"):
                mrs_reviewed.append(entry)

    return {
        "date": date,
        "commits": commits,
        "mrs_authored": mrs_authored,
        "mrs_reviewed": mrs_reviewed,
        "commit_count": sum(c["commit_count"] for c in commits),
        "mr_count": len(mrs_authored),
        "review_count": len(mrs_reviewed),
        "error": None,
    }


def main():
    host = os.environ.get("GITLAB_HOST", "").strip()
    token = os.environ.get("GITLAB_TOKEN", "").strip()
    date = sys.argv[1] if len(sys.argv) > 1 else datetime.now().strftime("%Y-%m-%d")

    if not host or not token:
        print(json.dumps({
            "date": date,
            "commits": [], "mrs_authored": [], "mrs_reviewed": [],
            "commit_count": 0, "mr_count": 0, "review_count": 0,
            "error": "未配置 GITLAB_HOST 或 GITLAB_TOKEN",
        }, ensure_ascii=False))
        return

    result = collect(host, token, date)
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
