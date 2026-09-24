#!/usr/bin/env python3
"""Reconcile one explicitly named OpenCode session at close time.

Defaults to dry-run. It never selects sessions by age and never changes
blocked/deferred todos. A done close requires a GitHub issue and commit/PR
reference, then backs up the database before updating that session's rows.
"""

from __future__ import annotations

import argparse
import json
import shutil
import sqlite3
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

DB = Path.home() / ".local/share/opencode/opencode.db"
LOG = Path.home() / ".local/share/opencode/session-reconciliations.log"


def now() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def parse_args(argv: list[str]) -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--session-id", required=False)
    p.add_argument("--issue", type=int, required=False)
    p.add_argument("--outcome", choices=("done", "blocked", "deferred"), required=False)
    p.add_argument("--ref", help="commit SHA or PR URL/reference; required for done")
    p.add_argument("--reason", help="required for blocked/deferred")
    p.add_argument("--repo", default="ons96/task-board")
    p.add_argument("--db", type=Path, default=DB)
    p.add_argument("--log", type=Path, default=LOG)
    p.add_argument("--apply", action="store_true", help="backup and mutate; default is dry-run")
    p.add_argument("--self-test", action="store_true")
    return p.parse_args(argv)


def validate(ns: argparse.Namespace) -> None:
    if ns.self_test:
        return
    missing = [name for name in ("session_id", "issue", "outcome") if getattr(ns, name) in (None, "")]
    if missing:
        raise SystemExit("missing required argument(s): " + ", ".join("--" + n.replace("_", "-") for n in missing))
    if ns.outcome == "done" and not ns.ref:
        raise SystemExit("--ref is required when --outcome done")
    if ns.outcome in ("blocked", "deferred") and not ns.reason:
        raise SystemExit("--reason is required when outcome is blocked/deferred")


def issue_exists(repo: str, number: int) -> bool:
    result = subprocess.run(
        ["gh", "issue", "view", str(number), "--repo", repo, "--json", "number"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return result.returncode == 0


def read_session(db: Path, session_id: str) -> tuple[tuple, list[tuple]]:
    uri = f"file:{db}?mode=ro"
    with sqlite3.connect(uri, uri=True) as conn:
        session = conn.execute(
            "SELECT id,title,directory FROM session WHERE id=?", (session_id,)
        ).fetchone()
        if session is None:
            raise SystemExit(f"session not found: {session_id}")
        todos = conn.execute(
            "SELECT position,status,priority,content FROM todo WHERE session_id=? ORDER BY position",
            (session_id,),
        ).fetchall()
    return session, todos


def backup_db(db: Path) -> Path:
    backup = db.with_name(f"{db.name}.bak.session-close-{now()}")
    shutil.copy2(db, backup)
    for suffix in ("-wal", "-shm"):
        sidecar = Path(str(db) + suffix)
        if sidecar.exists():
            shutil.copy2(sidecar, Path(str(backup) + suffix))
    return backup


def append_log(path: Path, entry: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(entry, sort_keys=True) + "\n")


def reconcile(ns: argparse.Namespace) -> int:
    validate(ns)
    if ns.self_test:
        return self_test()
    session, todos = read_session(ns.db, ns.session_id)
    pending = [row for row in todos if row[1] in ("pending", "in_progress")]
    if not issue_exists(ns.repo, ns.issue):
        raise SystemExit(f"GitHub issue does not exist or is inaccessible: {ns.repo}#{ns.issue}")
    if not pending:
        raise SystemExit("session has no pending/in-progress todos; refusing no-op close")

    entry = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "session_id": ns.session_id,
        "title": session[1],
        "issue": f"{ns.repo}#{ns.issue}",
        "outcome": ns.outcome,
        "ref": ns.ref or "",
        "reason": ns.reason or "",
        "todo_count": len(pending),
        "mode": "apply" if ns.apply else "dry-run",
    }
    print(json.dumps({**entry, "todos": [row[3] for row in pending]}, indent=2))
    if not ns.apply:
        return 0

    backup = backup_db(ns.db)
    entry["backup"] = str(backup)
    with sqlite3.connect(ns.db, timeout=60) as conn:
        conn.execute("PRAGMA busy_timeout=60000")
        conn.execute("BEGIN IMMEDIATE")
        if ns.outcome == "done":
            conn.execute(
                "UPDATE todo SET status='completed', time_updated=? "
                "WHERE session_id=? AND status IN ('pending','in_progress')",
                (int(datetime.now(timezone.utc).timestamp() * 1000), ns.session_id),
            )
        conn.commit()
    append_log(ns.log, entry)
    print(f"reconciled: {len(pending)} current-session todo(s); backup={backup}")
    return 0


def self_test() -> int:
    assert validate_args_for_test("done", None, None) == "--ref is required when --outcome done"
    assert validate_args_for_test("done", "abc", None) is None
    assert validate_args_for_test("blocked", None, None) == "--reason is required when outcome is blocked/deferred"
    assert validate_args_for_test("deferred", None, "waiting") is None
    print("self-test: ALL PASS")
    return 0


def validate_args_for_test(outcome: str, ref: str | None, reason: str | None) -> str | None:
    if outcome == "done" and not ref:
        return "--ref is required when --outcome done"
    if outcome in ("blocked", "deferred") and not reason:
        return "--reason is required when outcome is blocked/deferred"
    return None


if __name__ == "__main__":
    try:
        raise SystemExit(reconcile(parse_args(sys.argv[1:])))
    except KeyboardInterrupt:
        raise SystemExit(130)
