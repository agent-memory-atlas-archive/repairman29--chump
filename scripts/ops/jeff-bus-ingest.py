#!/usr/bin/env python3
"""jeff-bus-ingest.py — Phase A of "Mirror in the OS": the conversation bus INBOUND leg.

Tails Claude Code session transcripts (the ``*.jsonl`` files under the projects
dir) and appends each conversational turn into the canonical ``chump_memory.db``
``chump_web_messages`` table — the same store the web/PWA surface already uses
(schema owned by ``crates/chump-db-pool/src/db_pool.rs``). This makes the
operator<->fleet conversation legible to the fleet from one authoritative store
on the always-on hub, instead of only living in per-worktree transcript files.

SCOPE (Phase A, first slice): this is a PASSIVE, APPEND-ONLY LOG. It ingests the
inbound (transcript) side only. It never approves, decides, routes, or acts — a
later phase adds the outbound (fleet->operator) leg and an advisory twin. This
script must never gain a decision path.

DESIGN NOTES
  * Idempotent. Every Claude Code transcript line carries a globally-unique
    ``uuid``; we record ingested uuids in ``chump_bus_ingest_cursor`` and skip
    any we have already seen, so re-runs (the timer fires on a cadence) never
    double-insert.
  * Cheap in steady state. A per-file cursor (``chump_bus_file_cursor``) skips
    whole transcripts whose size+mtime are unchanged since the last pass, so the
    common case is "nothing new" and touches no rows.
  * Reuses, never re-invents. The message/session tables are the existing
    canonical ones; the two ``chump_bus_*`` cursor tables are the only new
    state, kept separate so the bus's bookkeeping never mutates the shared
    message schema.

CONFIG (env)
  CHUMP_MEMORY_DB_PATH   path to chump_memory.db (default: ./sessions/chump_memory.db,
                         matching db_pool's cwd-relative resolution)
  CHUMP_TRANSCRIPTS_DIR  dir tree of *.jsonl transcripts (default: ~/.claude/projects)
  CHUMP_BUS_BOT          value stored in chump_web_sessions.bot (default: claude-code)

Prints a one-line JSON summary to stdout on completion.
"""

from __future__ import annotations

import glob
import json
import os
import sqlite3
import sys
import time

DEFAULT_BOT = os.environ.get("CHUMP_BUS_BOT", "claude-code")
INGESTABLE_TYPES = ("user", "assistant")


def db_path() -> str:
    p = os.environ.get("CHUMP_MEMORY_DB_PATH")
    if p:
        return p
    return os.path.join(os.getcwd(), "sessions", "chump_memory.db")


def transcripts_dir() -> str:
    d = os.environ.get("CHUMP_TRANSCRIPTS_DIR")
    if d:
        return os.path.expanduser(d)
    return os.path.expanduser("~/.claude/projects")


def connect(path: str) -> sqlite3.Connection:
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    conn = sqlite3.connect(path, timeout=30.0)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=30000")
    conn.execute("PRAGMA foreign_keys=OFF")
    return conn


def ensure_schema(conn: sqlite3.Connection) -> None:
    """Create the canonical message/session tables (no-op if db_pool already made
    them) plus the two bus-owned cursor tables. The message/session DDL mirrors
    crates/chump-db-pool/src/db_pool.rs including its ALTER-added columns
    (thinking_monologue, feedback) so a FRESH db (e.g. the test) is compatible."""
    conn.executescript(
        """
        CREATE TABLE IF NOT EXISTS chump_web_sessions (
            id TEXT PRIMARY KEY,
            bot TEXT NOT NULL DEFAULT 'chump',
            title TEXT,
            created_at TEXT NOT NULL DEFAULT (datetime('now')),
            updated_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_web_sessions_updated
            ON chump_web_sessions(bot, updated_at DESC);

        CREATE TABLE IF NOT EXISTS chump_web_messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id TEXT NOT NULL,
            role TEXT NOT NULL CHECK (role IN ('user', 'assistant', 'system')),
            content TEXT NOT NULL,
            tool_calls_json TEXT,
            attachments_json TEXT,
            thinking_monologue TEXT,
            feedback INTEGER DEFAULT 0,
            created_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE INDEX IF NOT EXISTS idx_web_messages_session
            ON chump_web_messages(session_id, created_at);

        -- Bus-owned bookkeeping. These two tables are the ONLY new state; the
        -- message/session tables above are the existing canonical ones.
        CREATE TABLE IF NOT EXISTS chump_bus_ingest_cursor (
            source_uuid TEXT PRIMARY KEY,
            source TEXT NOT NULL,
            session_id TEXT,
            file TEXT,
            message_id INTEGER,
            ingested_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        CREATE TABLE IF NOT EXISTS chump_bus_file_cursor (
            file TEXT PRIMARY KEY,
            size INTEGER NOT NULL,
            mtime REAL NOT NULL,
            last_ingested_at TEXT NOT NULL DEFAULT (datetime('now'))
        );
        """
    )
    # Best-effort: rebuild the FTS index binding if db_pool's virtual table
    # exists. The insert triggers (owned by db_pool) keep it in sync on live
    # dbs; on a fresh test db there is no FTS table and that's fine.
    conn.commit()


def extract_turn(obj: dict) -> tuple[str, str, str | None] | None:
    """Return (role, text, thinking) for a conversational turn, or None to skip
    (tool-only echoes, empty turns, non-conversational line types)."""
    msg = obj.get("message")
    if not isinstance(msg, dict):
        return None
    role = msg.get("role") or obj.get("type")
    if role not in ("user", "assistant"):
        return None
    content = msg.get("content")

    text_parts: list[str] = []
    thinking_parts: list[str] = []
    if isinstance(content, str):
        text_parts.append(content)
    elif isinstance(content, list):
        for block in content:
            if not isinstance(block, dict):
                continue
            btype = block.get("type")
            if btype == "text" and isinstance(block.get("text"), str):
                text_parts.append(block["text"])
            elif btype == "thinking" and isinstance(block.get("thinking"), str):
                thinking_parts.append(block["thinking"])
            # tool_use / tool_result blocks are intentionally not treated as
            # conversational text — the bus logs dialogue, not tool plumbing.
    text = "\n".join(t for t in text_parts if t).strip()
    thinking = "\n".join(t for t in thinking_parts if t).strip() or None
    if not text:
        # An assistant turn that is pure tool_use, or a user turn that is pure
        # tool_result, carries no dialogue — skip it.
        return None
    return role, text, thinking


def ingest_file(conn: sqlite3.Connection, path: str, bot: str, stats: dict) -> None:
    cur = conn.cursor()
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                stats["lines_seen"] += 1
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                if obj.get("type") not in INGESTABLE_TYPES:
                    continue
                uuid = obj.get("uuid")
                session_id = obj.get("sessionId")
                if not uuid or not session_id:
                    continue

                row = cur.execute(
                    "SELECT 1 FROM chump_bus_ingest_cursor WHERE source_uuid = ?",
                    (uuid,),
                ).fetchone()
                if row is not None:
                    stats["skipped_duplicate"] += 1
                    continue

                turn = extract_turn(obj)
                if turn is None:
                    stats["skipped_empty"] += 1
                    continue
                role, text, thinking = turn
                created_at = obj.get("timestamp")

                # Ensure the session row exists (idempotent).
                cur.execute(
                    "INSERT OR IGNORE INTO chump_web_sessions (id, bot) VALUES (?, ?)",
                    (session_id, bot),
                )
                if cur.rowcount:
                    stats["sessions_upserted"] += 1

                cur.execute(
                    "INSERT INTO chump_web_messages "
                    "(session_id, role, content, thinking_monologue, created_at) "
                    "VALUES (?, ?, ?, ?, COALESCE(?, datetime('now')))",
                    (session_id, role, text, thinking, created_at),
                )
                message_id = cur.lastrowid
                cur.execute(
                    "INSERT OR IGNORE INTO chump_bus_ingest_cursor "
                    "(source_uuid, source, session_id, file, message_id) "
                    "VALUES (?, 'claude-code-transcript', ?, ?, ?)",
                    (uuid, session_id, path, message_id),
                )
                cur.execute(
                    "UPDATE chump_web_sessions SET updated_at = datetime('now') WHERE id = ?",
                    (session_id,),
                )
                stats["messages_inserted"] += 1
        conn.commit()
    except OSError as exc:
        conn.rollback()
        sys.stderr.write(f"[jeff-bus-ingest] skip {path}: {exc}\n")


def main() -> int:
    path = db_path()
    tdir = transcripts_dir()
    bot = DEFAULT_BOT
    conn = connect(path)
    ensure_schema(conn)

    stats = {
        "files_scanned": 0,
        "files_skipped_unchanged": 0,
        "lines_seen": 0,
        "sessions_upserted": 0,
        "messages_inserted": 0,
        "skipped_duplicate": 0,
        "skipped_empty": 0,
    }

    files = sorted(glob.glob(os.path.join(tdir, "**", "*.jsonl"), recursive=True))
    cur = conn.cursor()
    for f in files:
        try:
            st = os.stat(f)
        except OSError:
            continue
        prev = cur.execute(
            "SELECT size, mtime FROM chump_bus_file_cursor WHERE file = ?", (f,)
        ).fetchone()
        if prev is not None and prev[0] == st.st_size and prev[1] >= st.st_mtime:
            stats["files_skipped_unchanged"] += 1
            continue
        stats["files_scanned"] += 1
        ingest_file(conn, f, bot, stats)
        cur.execute(
            "INSERT INTO chump_bus_file_cursor (file, size, mtime) VALUES (?, ?, ?) "
            "ON CONFLICT(file) DO UPDATE SET size=excluded.size, mtime=excluded.mtime, "
            "last_ingested_at=datetime('now')",
            (f, st.st_size, st.st_mtime),
        )
        conn.commit()

    stats["db"] = path
    stats["transcripts_dir"] = tdir
    stats["generated_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    print(json.dumps(stats, separators=(",", ":")))
    conn.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
