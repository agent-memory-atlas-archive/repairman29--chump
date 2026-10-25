#!/usr/bin/env python3
"""discord-gateway.py — RESILIENT-266 serenity-free Discord receive gateway.

Opens an OUTBOUND WebSocket to Discord's gateway (no inbound endpoint, no domain,
no TLS to terminate, no serenity → sidesteps SECURITY-004's vulnerable rustls-webpki).
Receives operator DMs + button-click interactions and acts on them, replying via the
Discord REST API (the same path notify-operator.sh already uses).

This is the RECEIVE half of Chump<->operator Discord. The SEND half is
scripts/coord/lib/notify-operator.sh (bash+curl). Together = two-way.

Env:
  DISCORD_TOKEN            bot token (required)
  CHUMP_READY_DM_USER_ID   the ONLY user whose DMs/buttons are honored (required)
  CHUMP_REPO               repo root for status/exec commands (default cwd)
  CHUMP_DISCORD_GW_INTENTS override the intents bitfield (default DIRECT_MESSAGES)

Command surface (DM the bot):
  status | brief   → fleet ship-rate + recent merges
  ping             → pong (liveness)
  help             → this list
Button interactions:
  * "mergepr:<owner>/<repo>/<n>" / "rejectpr:<owner>/<repo>/<n>" — RESILIENT-265
    approve-from-phone: WIRED. The tap runs scripts/ops/pr-approval-action.sh
    (idempotent gh merge/close) and edits the message with the result. Only the
    operator (CHUMP_READY_DM_USER_ID) can act.
  * legacy "approve:<id>" / "deny:<id>" — acknowledged only (no action bound).

Run: DISCORD_TOKEN=... CHUMP_READY_DM_USER_ID=... python3 discord-gateway.py
Needs: pip install websockets
"""
from __future__ import annotations

import asyncio
import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path

try:
    import websockets
except ImportError:
    sys.stderr.write("discord-gateway: needs `pip install websockets`\n")
    sys.exit(3)

GATEWAY = "wss://gateway.discord.gg/?v=10&encoding=json"
API = "https://discord.com/api/v10"
TOKEN = os.environ.get("DISCORD_TOKEN", "").strip()
OPERATOR = os.environ.get("CHUMP_READY_DM_USER_ID", "").strip()
REPO = os.environ.get("CHUMP_REPO", os.getcwd())
AMBIENT = Path(REPO) / ".chump-locks" / "ambient.jsonl"
# INFRA-3607 OBSERVABILITY: dispatched agents (command + advisor) used to send
# stdout/stderr to DEVNULL, which hid a silent advisor crash ("HOME: unbound
# variable") for a whole night. Capture both streams to a log so the next
# failure is visible, not silent. Best-effort: falls back to DEVNULL if the
# file cannot be opened.
DISPATCH_LOG = Path(REPO) / ".chump-locks" / "discord-dispatch.log"


def _open_dispatch_log(tag: str):
    try:
        DISPATCH_LOG.parent.mkdir(parents=True, exist_ok=True)
        fh = open(DISPATCH_LOG, "ab")
        stamp = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        fh.write(("\n===== %s %s =====\n" % (stamp, tag)).encode())
        fh.flush()
        return fh
    except Exception:
        return None
# DIRECT_MESSAGES (1<<12). Interactions are delivered regardless of intents.
# MESSAGE_CONTENT (1<<15) is privileged; enable it in the dev portal to read DM text.
INTENTS = int(os.environ.get("CHUMP_DISCORD_GW_INTENTS", str(1 << 12)))

# ── CROSS-NODE SINGLETON (RESILIENT-370) ─────────────────────────────────────
# The operator channel must have ONE voice. Two nodes connecting the SAME bot
# token each receive every operator DM and each fire their own reply, so the
# operator gets DOUBLE messages from competing responders — the exact CJ+Pixel
# "hot mess" this guard exists to kill. The beat wrapper (scripts/dispatch/
# discord-gateway-beat.sh) already dedups WITHIN a node via a pidfile, but a
# pidfile cannot see a second node. This .py is the ONE chokepoint every install
# path funnels through (systemd unit, Termux runit organ, or a manual run), so
# the cross-node guard lives here.
#
#   CHUMP_DISCORD_GATEWAY_NODE unset      -> run (backward-compatible; the
#                                            single-node / dev case)
#   set and matches this host             -> run (I am the canonical voice)
#   set and does NOT match this host      -> stand by: never connect, idle
#                                            quietly so no duplicate reply is
#                                            ever sent from this node
#
# The value is a hostname (short or FQDN) or a CHUMP_NODE_ID; it lives per-node
# in ~/.chump/providers.env, the same place the creds already live. Promoting a
# different node to canonical is a one-line config change + restart — no code.
CANONICAL_NODE = os.environ.get("CHUMP_DISCORD_GATEWAY_NODE", "").strip()


def _this_host() -> str:
    """This node's identity for the singleton check — CHUMP_NODE_ID wins, else
    the OS hostname."""
    return (os.environ.get("CHUMP_NODE_ID", "").strip()
            or socket.gethostname().strip())


def is_canonical_node() -> bool:
    """True if this node may run the gateway. Unset marker => always true
    (backward-compatible). Otherwise the marker must match this host's full or
    short hostname (or CHUMP_NODE_ID), so `closetjunky` matches a box whose FQDN
    is `closetjunky.local`."""
    if not CANONICAL_NODE:
        return True
    host = _this_host()
    return CANONICAL_NODE in (host, host.split(".")[0])

# Opcodes
OP_DISPATCH, OP_HEARTBEAT, OP_IDENTIFY = 0, 1, 2
OP_RECONNECT, OP_INVALID_SESSION, OP_HELLO, OP_HEARTBEAT_ACK = 7, 9, 10, 11


def now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def emit(kind: str, **extra) -> None:
    """Best-effort ambient event — mirrors the fleet's observability."""
    try:
        AMBIENT.parent.mkdir(parents=True, exist_ok=True)
        rec = {"ts": now(), "kind": kind, **extra}
        with AMBIENT.open("a", encoding="utf-8") as f:
            f.write(json.dumps(rec, separators=(",", ":")) + "\n")
    except Exception:
        pass


def _curl_post(url: str, payload: dict) -> int:
    """POST JSON with the bot auth. Returns HTTP code (0 on transport error)."""
    try:
        out = subprocess.run(
            ["curl", "-sS", "--max-time", "10", "-o", "/dev/null",
             "-w", "%{http_code}", "-X", "POST", url,
             "-H", f"Authorization: Bot {TOKEN}",
             "-H", "Content-Type: application/json",
             "-d", json.dumps(payload)],
            capture_output=True, text=True, timeout=15,
        )
        return int(out.stdout.strip() or 0)
    except Exception:
        return 0


def send_dm(content: str) -> None:
    """Open the operator DM channel and post a message (REST, no serenity)."""
    try:
        ch = subprocess.run(
            ["curl", "-sS", "--max-time", "10", "-X", "POST",
             f"{API}/users/@me/channels",
             "-H", f"Authorization: Bot {TOKEN}",
             "-H", "Content-Type: application/json",
             "-d", json.dumps({"recipient_id": OPERATOR})],
            capture_output=True, text=True, timeout=15,
        )
        ch_id = json.loads(ch.stdout).get("id")
        if ch_id:
            _curl_post(f"{API}/channels/{ch_id}/messages", {"content": content[:1990]})
    except Exception:
        pass


def run_status() -> str:
    """Cheap ground-truth status the operator can ask for from their phone."""
    try:
        merges = subprocess.run(
            ["git", "-C", REPO, "log", "origin/main", "--since=1 hour ago", "--oneline"],
            capture_output=True, text=True, timeout=15,
        ).stdout.strip().splitlines()
        head = subprocess.run(
            ["git", "-C", REPO, "log", "origin/main", "--oneline", "-1"],
            capture_output=True, text=True, timeout=10,
        ).stdout.strip()
        n = len(merges)
        lines = "\n".join(f"• {m}" for m in merges[:6]) or "• (none in last hour)"
        return f"**Fleet status** — {n} merge(s) in the last hour.\nHEAD: {head}\n{lines}"
    except Exception as e:
        return f"status error: {e}"


QUICK_COMMANDS = ("status", "brief", "fleet", "ping", "help", "?", "commands")

DISPATCH_SCRIPT = Path(REPO) / "scripts" / "dispatch" / "discord-command-agent.sh"
# INFRA-3596: cap concurrent fresh-agent dispatches so a burst of DMs can't
# fan out unbounded `claude -p` processes (cost + resource guard alongside
# the per-invocation --max-budget-usd inside the script itself).
MAX_CONCURRENT_DISPATCHES = int(os.environ.get("CHUMP_DISCORD_AGENT_MAX_CONCURRENT", "1"))
_dispatch_semaphore: "asyncio.Semaphore | None" = None

# INFRA-3597: The Advisor — DISTINCT from the ops command agent above. The
# ops agent ACTS on a DM (may file gaps); the Advisor only reads + replies,
# never mutates anything. Reached with an explicit "advisor"/"advise" prefix
# so Jeff can choose "act on this" (default free text -> ops agent) vs. "just
# tell me" (advisor prefix) from the same DM thread.
ADVISOR_SCRIPT = Path(REPO) / "scripts" / "dispatch" / "discord-advisor-agent.sh"
ADVISOR_TRIGGERS = ("advisor", "advise")
MAX_CONCURRENT_ADVISOR_DISPATCHES = int(os.environ.get("CHUMP_DISCORD_ADVISOR_MAX_CONCURRENT", "1"))
_advisor_semaphore: "asyncio.Semaphore | None" = None


def handle_command(text: str) -> str:
    cmd = text.strip().lower().split()[0] if text.strip() else ""
    if cmd in ("status", "brief", "fleet"):
        return run_status()
    if cmd == "ping":
        return "pong ✅ (gateway online, receiving)"
    if cmd in ("help", "?", "commands"):
        return ("Chump gateway — try: `status` (ship-rate + recent merges), "
                "`ping` (liveness), `help`, `advisor <question>` (read-only "
                "Advisor — knows the fleet, never acts), or any other "
                "free-text command/question — a fresh Chump agent will read "
                "board state, act, and reply.")
    return ""


def extract_advisor_question(text: str) -> "str | None":
    """Returns the question text if `text` opens with an Advisor trigger
    word ("advisor"/"advise"), else None. Case-insensitive; the trigger word
    itself is stripped from what's handed to the Advisor agent."""
    stripped = text.strip()
    if not stripped:
        return None
    parts = stripped.split(None, 1)
    if parts[0].lower() not in ADVISOR_TRIGGERS:
        return None
    return parts[1].strip() if len(parts) > 1 else ""


async def dispatch_command_agent(text: str) -> None:
    """INFRA-3596 DISPATCH: hand a free-text operator command to a fresh,
    bounded `claude -p` agent (scripts/dispatch/discord-command-agent.sh) that
    reads board state and replies via notify_operator itself. Fire-and-forget
    from the gateway's perspective — awaiting the subprocess here would block
    the single-threaded gateway loop (heartbeats, other DMs) for the agent's
    full runtime, so this runs as a background task instead."""
    global _dispatch_semaphore
    if _dispatch_semaphore is None:
        _dispatch_semaphore = asyncio.Semaphore(MAX_CONCURRENT_DISPATCHES)
    # scanner-anchor: "kind":"discord_command_agent_dispatch_failed"
    async with _dispatch_semaphore:
        if not DISPATCH_SCRIPT.exists():
            emit("discord_command_agent_dispatch_failed", reason="script_missing")
            send_dm("(command agent dispatch script is missing — cannot act on that yet.)")
            return
        try:
            _log = _open_dispatch_log("command-agent: %s" % text[:80])
            _out = _log if _log is not None else asyncio.subprocess.DEVNULL
            _err = asyncio.subprocess.STDOUT if _log is not None else asyncio.subprocess.DEVNULL
            proc = await asyncio.create_subprocess_exec(
                "bash", str(DISPATCH_SCRIPT), text,
                cwd=REPO,
                stdin=asyncio.subprocess.DEVNULL,
                stdout=_out,
                stderr=_err,
            )
            await proc.wait()
            if _log is not None:
                _log.close()
        except Exception as e:
            emit("discord_command_agent_dispatch_failed", reason=str(e)[:160])
            send_dm(f"(couldn't start the command agent: {e})")


# INFRA-3608 FAST ADVISOR. A plain operator DM is a CHAT, not a research job.
# The old advisor spawned a full agentic `claude -p` session (almanac + tool
# round-trips + compose + notify) that took 30-90s per message. This fast path
# answers with a SINGLE lightweight LLM completion (Groq llama-3.3-70b, ~1s;
# claude single-shot fallback) — read-only, no tools, no gaps — so the seat
# replies in seconds. An explicit "deep <question>" (or "dig"/"research") still
# routes to the heavy fleet-aware agent for research-grade answers.
FAST_ADVISOR_MODEL_GROQ = os.environ.get(
    "CHUMP_ADVISOR_FAST_MODEL", "llama-3.3-70b-versatile")
FAST_ADVISOR_MAX_TOKENS = int(os.environ.get("CHUMP_ADVISOR_FAST_MAX_TOKENS", "320"))
DEEP_ADVISOR_PREFIXES = ("deep ", "dig ", "research ")
FAST_ADVISOR_SYSTEM = (
    "You are the Advisor -- Chump/ChumpOS's read-only conversational companion "
    "for Jeff, the operator. ChumpOS is an autonomous multi-agent software "
    "factory running across a fleet of ~100 repos; helsinki is the primary "
    "always-on node. Reply in a warm, terse, conversational voice: 1-3 short "
    "sentences, plain text only (no markdown tables or headers -- it may be read "
    "aloud). You are STRICTLY READ-ONLY: never say you filed a gap, merged a PR, "
    "restarted a service, or changed any state -- you only advise. If a question "
    "needs live fleet data you don't have in front of you, say so briefly and "
    "suggest the operator send `deep <question>` for the full fleet-aware "
    "advisor. Never invent PR numbers, gap IDs, file paths, or statuses you were "
    "not given."
)


def _advisor_context() -> str:
    """Cheap, near-instant fleet context to ground the fast reply. LOCAL git
    reads only (no network, no gh, no almanac) so it stays sub-second alongside
    the Groq call -- proven ~0.3s end-to-end. Gives the fast seat enough real
    ground truth to answer the common "what is the fleet doing?" DM without
    punting every status question to the slow deep agent."""
    try:
        head = subprocess.run(
            ["git", "-C", REPO, "log", "origin/main", "--oneline", "-1"],
            capture_output=True, text=True, timeout=8,
        ).stdout.strip() or "(unknown)"
    except Exception:
        head = "(unknown)"
    try:
        merges = subprocess.run(
            ["git", "-C", REPO, "log", "origin/main", "--since=2 hours ago",
             "--pretty=%s"],
            capture_output=True, text=True, timeout=8,
        ).stdout.strip().splitlines()
    except Exception:
        merges = []
    if merges:
        recent = "; ".join(m for m in merges[:5])
        return (f"latest origin/main commit: {head}. "
                f"{len(merges)} commit(s) landed on main in the last 2h -- "
                f"most recent: {recent}")
    return (f"latest origin/main commit: {head}. "
            f"No commits landed on main in the last 2h (fleet may be quiet, "
            f"stalled, or working in unmerged PRs -- you do not have live PR "
            f"state here, so say so rather than guessing).")


async def _fast_complete_groq(user: str) -> "str | None":
    """Single Groq chat completion (OpenAI-compatible). ~0.2-1s. Returns None
    on any error so the caller can fall back."""
    key = os.environ.get("GROQ_API_KEY", "").strip()
    if not key:
        return None
    body = json.dumps({
        "model": FAST_ADVISOR_MODEL_GROQ,
        "messages": [
            {"role": "system", "content": FAST_ADVISOR_SYSTEM},
            {"role": "user", "content": user},
        ],
        "max_tokens": FAST_ADVISOR_MAX_TOKENS,
        "temperature": 0.4,
    })
    try:
        proc = await asyncio.create_subprocess_exec(
            "curl", "-sS", "--max-time", "12",
            "https://api.groq.com/openai/v1/chat/completions",
            "-H", f"Authorization: Bearer {key}",
            "-H", "Content-Type: application/json",
            "-d", body,
            stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )
        out, _ = await proc.communicate()
        j = json.loads(out.decode())
        msg = (j.get("choices") or [{}])[0].get("message", {}).get("content")
        if msg and msg.strip():
            return msg.strip()
    except Exception:
        return None
    return None


COO_REPLY_SCRIPT = Path(REPO) / "scripts" / "dispatch" / "coo-reply.sh"


async def _fast_complete_claude(user: str) -> "str | None":
    """Fallback: one read-only claude completion via scripts/dispatch/coo-reply.sh
    (RESILIENT-1655: strict Read,Grep,Glob allowlist, no write/edit/bash tools)."""
    prompt = FAST_ADVISOR_SYSTEM + "\n\n" + user
    try:
        if COO_REPLY_SCRIPT.exists():
            cmd = ["bash", str(COO_REPLY_SCRIPT), "--prompt", prompt]
        else:
            cmd = [
                "claude", "-p", prompt, "--model", "sonnet",
                "--allowedTools", "Read,Grep,Glob",
                "--disallowedTools", "Bash,Edit,Write,NotebookEdit",
            ]
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            cwd=REPO,
            stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL,
        )
        try:
            out, _ = await asyncio.wait_for(proc.communicate(), timeout=25)
        except asyncio.TimeoutError:
            try:
                proc.kill()
            except Exception:
                pass
            return None
        txt = out.decode().strip()
        if txt and "retired" not in txt.lower() and "issue with the selected model" not in txt.lower():
            return txt
    except Exception:
        return None
    return None


async def fast_advisor_reply(question: str) -> "str | None":
    """Fast, read-only, no-tools conversational reply. Groq first, claude
    single-shot fallback, None if every provider fails."""
    user = (
        f"[fleet context] {_advisor_context()}\n\n"
        f"Jeff asks: {question}"
    )
    reply = await _fast_complete_groq(user)
    if reply:
        return reply
    return await _fast_complete_claude(user)


async def dispatch_advisor_agent(question: str) -> None:
    """INFRA-3608: FAST conversational Advisor seat. A plain DM gets a single
    lightweight LLM completion (Groq ~1s, claude fallback) -- read-only, no
    tools, no gaps -- so the reply lands in seconds. `deep <question>` routes
    to the heavy fleet-aware agent (_dispatch_deep_advisor) for research."""
    global _advisor_semaphore
    if _advisor_semaphore is None:
        _advisor_semaphore = asyncio.Semaphore(MAX_CONCURRENT_ADVISOR_DISPATCHES)
    async with _advisor_semaphore:
        # scanner-anchor: "kind":"discord_advisor_agent_dispatch_failed" (INFRA-3608).
        # The emit sites below call the dynamic emit() helper, which the
        # grep-based EVENT_REGISTRY audit cannot see; this literal keeps
        # register-and-emit in sync, mirroring the command-agent anchor above.
        q = (question or "").strip()
        if not q:
            send_dm("(ask me something -- e.g. `what's blocking the fleet right now?`)")
            return
        low = q.lower()
        if low.startswith(DEEP_ADVISOR_PREFIXES):
            deep_parts = q.split(None, 1)
            await _dispatch_deep_advisor(deep_parts[1] if len(deep_parts) > 1 else "")
            return
        print(f"[discord-gateway] advisor(fast): {q[:80]}", flush=True)
        reply = None
        try:
            reply = await fast_advisor_reply(q)
        except Exception as e:
            emit("discord_advisor_agent_dispatch_failed", reason=str(e)[:160])
        if reply:
            send_dm(reply)
            print(f"[discord-gateway] advisor(fast) replied {len(reply)} chars", flush=True)
        else:
            send_dm("(couldn't reach a model just now -- try again in a moment, or "
                    "send `deep <question>` for the full fleet-aware advisor.)")


async def _dispatch_deep_advisor(question: str) -> None:
    """The heavy, fleet-aware agentic advisor (scripts/dispatch/
    discord-advisor-agent.sh): almanac + live gap/PR/ambient reads, replies via
    notify_operator itself. Slow (30-90s) but research-grade; reached only via
    an explicit `deep`/`dig`/`research` prefix. stdout/stderr captured to the
    dispatch log (INFRA-3607) so a failure is visible, not silent."""
    if not question:
        send_dm("(ask a deep question -- e.g. `deep what's blocking PR 2780 and why`.)")
        return
    if not ADVISOR_SCRIPT.exists():
        emit("discord_advisor_agent_dispatch_failed", reason="script_missing")
        send_dm("(deep advisor dispatch script is missing -- cannot answer that yet.)")
        return
    send_dm("(digging into that -- the deep advisor takes a bit...)")
    try:
        _log = _open_dispatch_log("advisor-agent(deep): %s" % question[:80])
        _out = _log if _log is not None else asyncio.subprocess.DEVNULL
        _err = asyncio.subprocess.STDOUT if _log is not None else asyncio.subprocess.DEVNULL
        proc = await asyncio.create_subprocess_exec(
            "bash", str(ADVISOR_SCRIPT), question,
            cwd=REPO,
            stdin=asyncio.subprocess.DEVNULL,
            stdout=_out,
            stderr=_err,
        )
        await proc.wait()
        if _log is not None:
            _log.close()
    except Exception as e:
        emit("discord_advisor_agent_dispatch_failed", reason=str(e)[:160])
        send_dm(f"(couldn't start the deep advisor agent: {e})")


# RESILIENT-265 — the ACTION half of approve-from-phone. The detector organ
# (scripts/dispatch/pr-approval-surface-beat.sh) DMs the operator a product-repo
# PR with ✅ Merge / ❌ Reject buttons whose custom_ids are `mergepr:<owner>/<repo>/<n>`
# and `rejectpr:<owner>/<repo>/<n>`. This handler is the ONE codepath a real tap
# triggers: it shells out to scripts/ops/pr-approval-action.sh (the same script
# the proof harness invokes directly), which does the idempotent gh work, then
# edits the original Discord message to the result and strips the buttons so the
# decision can't be re-tapped by accident.
PR_APPROVAL_ACTION = Path(REPO) / "scripts" / "ops" / "pr-approval-action.sh"

# EVENT_REGISTRY scanner-anchors (INFRA-754): the emit() calls below pass the
# kind to a dynamic helper, invisible to the grep-based event-registry rule.
# These literal anchors keep register-and-emit in sync (all registered in
# docs/observability/EVENT_REGISTRY.yaml):
#   scanner-anchor: "kind":"discord_pr_approval_tap"
#   scanner-anchor: "kind":"discord_pr_approval_done"
#   scanner-anchor: "kind":"discord_pr_approval_failed"


def _parse_pr_custom_id(custom_id: str):
    """`mergepr:owner/repo/number` → ("merge", "owner/repo", "number"); None if
    it doesn't parse."""
    if ":" not in custom_id:
        return None
    prefix, rest = custom_id.split(":", 1)
    action = {"mergepr": "merge", "rejectpr": "reject"}.get(prefix)
    if not action:
        return None
    parts = rest.split("/")
    if len(parts) < 3 or not parts[-1].isdigit():
        return None
    number = parts[-1]
    repo = "/".join(parts[:-1])
    return action, repo, number


def _http_code_and_body(out) -> "tuple[int, str]":
    """Split a curl `-w \n%{http_code}` result into (code, body)."""
    body, _, code = (out.stdout or "").rpartition("\n")
    try:
        return int(code.strip() or 0), body
    except ValueError:
        return 0, out.stdout or ""


def _edit_original_interaction(app_id: str, tok: str, content: str) -> int:
    """PATCH the interaction's @original message (webhook path) — set result text
    and REMOVE the buttons (components: []) so it can't be re-tapped. Returns the
    HTTP code (0 on transport error) and LOGS the code+body on failure. The
    RESILIENT-265 feedback bug lived here: this edit sent output to /dev/null and
    swallowed every exception, so when it failed the operator saw a dead button
    and nothing was logged. Make the result observable."""
    try:
        out = subprocess.run(
            ["curl", "-sS", "--max-time", "12", "-w", "\n%{http_code}",
             "-X", "PATCH", f"{API}/webhooks/{app_id}/{tok}/messages/@original",
             "-H", "Content-Type: application/json",
             "-d", json.dumps({"content": content[:1990], "components": []})],
            capture_output=True, text=True, timeout=15,
        )
        code, body = _http_code_and_body(out)
        if code // 100 != 2:
            print(f"[discord-gateway] edit @original failed HTTP {code}: {body[:200]}", flush=True)
        return code
    except Exception as e:
        print(f"[discord-gateway] edit @original error: {e}", flush=True)
        return 0


def _edit_channel_message(channel_id: str, message_id: str, content: str) -> int:
    """PATCH the button message directly via the BOT token (independent of the
    interaction/webhook token). Removes the buttons + sets result text. Returns
    the HTTP code (0 on transport/no-ids). This is the ROBUST PRIMARY feedback
    path: a bot editing its own DM message does not depend on the interaction
    token that was failing silently — so the button message reliably updates in
    place."""
    if not channel_id or not message_id or not TOKEN:
        return 0
    try:
        out = subprocess.run(
            ["curl", "-sS", "--max-time", "12", "-w", "\n%{http_code}",
             "-X", "PATCH", f"{API}/channels/{channel_id}/messages/{message_id}",
             "-H", f"Authorization: Bot {TOKEN}",
             "-H", "Content-Type: application/json",
             "-d", json.dumps({"content": content[:1990], "components": []})],
            capture_output=True, text=True, timeout=15,
        )
        code, body = _http_code_and_body(out)
        if code // 100 != 2:
            print(f"[discord-gateway] edit channel-msg failed HTTP {code}: {body[:200]}", flush=True)
        return code
    except Exception as e:
        print(f"[discord-gateway] edit channel-msg error: {e}", flush=True)
        return 0


def _report_pr_result(app_id: str, tok: str, channel_id: str,
                      message_id: str, status: str) -> None:
    """Guarantee the operator SEES the outcome of a tap — the RESILIENT-265
    feedback fix. TWO things happen because they solve two different problems:

      1) EDIT the button message in place — strip the buttons (so a
         seemingly-dead button can't be re-tapped) and show the result inline.
         Bot-token channel edit first (reliable, independent of the interaction
         token), @original webhook edit as backup.

      2) ALWAYS send a FRESH operator DM with the result. THIS is the
         load-bearing fix. On the 2026-08-13 incident the in-place edit
         SUCCEEDED server-side (the button message's edited_timestamp proved it)
         yet the operator saw nothing and re-tapped a button that was already
         gone — a Discord mobile client does not surface an EDIT of an existing
         message, but a NEW message pushes a notification. So a fresh DM, not
         (only) an edit, is what the operator actually sees. One DM per
         deliberate tap is a confirmation, not a pager — it bypasses the
         escalation suppress-registry by design (send_dm is a direct post)."""
    edited = (_edit_channel_message(channel_id, message_id, status) // 100 == 2
              or _edit_original_interaction(app_id, tok, status) // 100 == 2)
    print(f"[discord-gateway] feedback: buttons {'removed' if edited else 'edit-FAILED'}; "
          f"DM confirmation → {status[:80]}", flush=True)
    # Fresh DM = the guaranteed-visible confirmation. Never silent.
    send_dm(status)


async def handle_pr_approval_interaction(app_id: str, tok: str, custom_id: str,
                                        channel_id: str = "", message_id: str = "") -> None:
    """Operator tapped ✅ Merge / ❌ Reject on a product-repo PR. Run the real
    action (idempotent — a second tap on an already-acted PR is a clean no-op)
    and report the outcome back so the operator ALWAYS sees it (channel edit →
    @original edit → DM fallback, via _report_pr_result)."""
    parsed = _parse_pr_custom_id(custom_id)
    if parsed is None:
        _report_pr_result(app_id, tok, channel_id, message_id, f"couldn't parse `{custom_id}` ⚠️")
        return
    action, repo, number = parsed
    if not PR_APPROVAL_ACTION.exists():
        emit("discord_pr_approval_failed", custom_id=custom_id, reason="action_script_missing")
        _report_pr_result(app_id, tok, channel_id, message_id,
                          "(PR-approval action script missing — can't act yet ⚠️)")
        return
    emit("discord_pr_approval_tap", action=action, repo=repo, number=number)
    print(f"[discord-gateway] PR approval tap: {action} {repo}#{number}", flush=True)
    try:
        proc = await asyncio.create_subprocess_exec(
            "bash", str(PR_APPROVAL_ACTION), action, repo, number,
            cwd=REPO,
            stdin=asyncio.subprocess.DEVNULL,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
        )
        out, _ = await asyncio.wait_for(proc.communicate(), timeout=90)
        status = (out.decode().strip().splitlines() or ["(no output)"])[-1]
    except asyncio.TimeoutError:
        status = f"{repo}#{number}: action timed out ⚠️ (check GitHub)"
    except Exception as e:
        status = f"{repo}#{number}: action error — {e} ⚠️"
    emit("discord_pr_approval_done", action=action, repo=repo, number=number, status=status[:200])
    _report_pr_result(app_id, tok, channel_id, message_id, status)


async def gateway_loop() -> None:
    seq = None
    async with websockets.connect(GATEWAY, max_size=2**20) as ws:
        hello = json.loads(await ws.recv())
        interval = hello["d"]["heartbeat_interval"] / 1000.0

        async def heartbeat():
            while True:
                await asyncio.sleep(interval)
                try:
                    await ws.send(json.dumps({"op": OP_HEARTBEAT, "d": seq}))
                except Exception:
                    return

        await ws.send(json.dumps({
            "op": OP_IDENTIFY,
            "d": {"token": TOKEN, "intents": INTENTS,
                  "properties": {"os": "linux", "browser": "chump", "device": "chump"}},
        }))
        hb = asyncio.create_task(heartbeat())
        emit("discord_gateway_connected", intents=INTENTS)
        print(f"[discord-gateway] connected, intents={INTENTS}", flush=True)

        try:
            async for raw in ws:
                msg = json.loads(raw)
                if msg.get("s") is not None:
                    seq = msg["s"]
                op = msg.get("op")
                if op in (OP_RECONNECT, OP_INVALID_SESSION):
                    print("[discord-gateway] reconnect requested", flush=True)
                    return
                if op != OP_DISPATCH:
                    continue
                t, d = msg.get("t"), msg.get("d", {})

                if t == "READY":
                    u = d.get("user", {})
                    print(f"[discord-gateway] READY as {u.get('username')}#{u.get('discriminator')}", flush=True)
                    continue

                if t == "MESSAGE_CREATE":
                    # DMs only (guild_id absent), from the operator only, ignore our own.
                    if d.get("guild_id") or str(d.get("author", {}).get("id")) != OPERATOR:
                        continue
                    content = d.get("content", "")
                    if not content:  # MESSAGE_CONTENT intent off → empty; nudge once
                        send_dm("(I received your DM but can't read its text — enable the "
                                "MESSAGE CONTENT intent in the Discord dev portal. Buttons "
                                "and `status` still work.)")
                        continue
                    emit("discord_operator_command", command=content[:120])
                    print(f"[discord-gateway] operator: {content[:80]}", flush=True)
                    advisor_question = extract_advisor_question(content)
                    if advisor_question is not None:
                        # INFRA-3597: explicit "advisor"/"advise" prefix routes
                        # to the read-only Advisor instead of the ops command
                        # agent — checked first so it wins even over quick
                        # built-ins (e.g. "advisor status" asks the Advisor
                        # to explain status, not run the built-in).
                        # scanner-anchor: "kind":"discord_advisor_command"
                        emit("discord_advisor_command", question=advisor_question[:120])
                        asyncio.create_task(dispatch_advisor_agent(advisor_question))
                        continue
                    reply = handle_command(content)
                    if reply:
                        send_dm(reply)
                    else:
                        # Not a quick built-in -> the read-only Advisor
                        # (INFRA-3597), Jeff's conversational seat: it KNOWS
                        # the fleet (almanac + live state) and TALKS back,
                        # never mutating anything. Ops fix 2026-08-13: plain
                        # DMs used to route to the ACTING command agent,
                        # whose claude invocation was broken by an
                        # --allowedTools word-split (Bash(chump --briefing*)
                        # leaked --briefing*) as a bogus CLI option so claude
                        # exited 1 and Jeff only ever got the agent-failed
                        # fallback, never an answer). The advisor builds
                        # --allowedTools as an array and replies via the
                        # direct notify-operator form, so it delivers.
                        asyncio.create_task(dispatch_advisor_agent(content))
                    continue

                if t == "INTERACTION_CREATE":
                    inter_id, tok = d.get("id"), d.get("token")
                    custom_id = d.get("data", {}).get("custom_id", "")
                    uid = str(d.get("member", {}).get("user", {}).get("id")
                              or d.get("user", {}).get("id"))
                    if uid != OPERATOR:
                        # ACK so the client doesn't error, but do nothing.
                        _curl_post(f"{API}/interactions/{inter_id}/{tok}/callback",
                                   {"type": 4, "data": {"content": "not authorized", "flags": 64}})
                        continue
                    emit("discord_operator_interaction", custom_id=custom_id)
                    print(f"[discord-gateway] button: {custom_id}", flush=True)
                    app_id = d.get("application_id")
                    # Message the button lives on — used for the bot-token
                    # channel edit (the reliable feedback path, RESILIENT-265).
                    channel_id = str(d.get("channel_id")
                                     or d.get("message", {}).get("channel_id") or "")
                    message_id = str(d.get("message", {}).get("id") or "")
                    # RESILIENT-265 "approve-from-phone": a mergepr:/rejectpr:
                    # tap ACTS. Defer-ack within Discord's 3s window (type 6 =
                    # DEFERRED_UPDATE_MESSAGE — keeps the message + buttons up
                    # while we work), then run the real gh action in the
                    # background and edit the original message with the result.
                    if custom_id.startswith(("mergepr:", "rejectpr:")):
                        _curl_post(f"{API}/interactions/{inter_id}/{tok}/callback",
                                   {"type": 6})  # deferred update, no visible change yet
                        asyncio.create_task(handle_pr_approval_interaction(
                            app_id, tok, custom_id, channel_id, message_id))
                        continue
                    # Legacy approve:/deny: (and anything else): ack only.
                    _curl_post(f"{API}/interactions/{inter_id}/{tok}/callback",
                               {"type": 4, "data": {
                                   "content": f"received `{custom_id}` ✅ (no action bound)",
                                   "flags": 64}})
                    continue
        finally:
            hb.cancel()


async def main() -> None:
    if not TOKEN or not OPERATOR:
        sys.stderr.write("discord-gateway: DISCORD_TOKEN and CHUMP_READY_DM_USER_ID required\n")
        sys.exit(2)
    # CROSS-NODE SINGLETON (RESILIENT-370): if a canonical node is declared and
    # this is NOT it, stand by forever instead of connecting — never open a
    # second WebSocket on the same token (which would double every operator
    # reply). Idle (not exit) so neither systemd Restart=always nor runit
    # hot-loops, and is-active stays green: the organ is installed-and-standing-
    # by, not failed. Promoting this node (config + restart) flips it on.
    if not is_canonical_node():
        emit("discord_gateway_standby", canonical=CANONICAL_NODE, host=_this_host())
        print(f"[discord-gateway] standby: canonical node is '{CANONICAL_NODE}', "
              f"this is '{_this_host()}' — not connecting (cross-node singleton). "
              f"Set CHUMP_DISCORD_GATEWAY_NODE to this host + restart to take over.",
              flush=True)
        while True:
            await asyncio.sleep(3600)
    backoff = 2
    while True:
        try:
            await gateway_loop()
            backoff = 2
        except Exception as e:
            emit("discord_gateway_disconnected", error=str(e)[:160])
            print(f"[discord-gateway] disconnected: {e}; retry in {backoff}s", flush=True)
        await asyncio.sleep(backoff)
        backoff = min(backoff * 2, 60)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        pass
