---
doc_tag: design-spec
last_audited: 2026-05-13
audience: fleet engineers, external reviewers
purpose: Formal semantics of the per-session mailbox primitive
implements: INFRA-1115 (META-061 Layer-1 tactical)
---
# A2A Mailbox — formal semantics

Companion to the operator guide [`A2A_MAILBOX.md`](../process/A2A_MAILBOX.md). This doc pins down the delivery / ordering / persistence guarantees and lists the open edge cases so future layers can compose against a stable contract.

## Storage

- **Inbox file:** `.chump-locks/inbox/<recipient-session-id>.jsonl`. JSONL, one event per line. Permissions: `0644` (override `CHUMP_INBOX_MODE` to tighten on multi-user hosts).
- **Cursor file:** `.chump-locks/inbox/<recipient>.cursor`. ASCII integer = last-read byte offset.
- **Lock file:** `.chump-locks/inbox/.<recipient>.lock`. Used only when `flock(1)` is available.
- **Archive:** `.chump-locks/inbox-archive/<session>/<yyyy-mm>.jsonl.gz`. Gzip-appended monthly.

All paths are computed against the **main repo** (resolved via `git rev-parse --git-common-dir`), not the worktree — so a sender in one linked worktree reaches a recipient in another.

## Event schema

Same shape as `broadcast.sh` ambient events, with one optional addition:

```
{
  "event":   "INTENT|HANDOFF|STUCK|DONE|WARN|ALERT",
  "session": "<sender-session-id>",
  "ts":      "<RFC-3339-UTC>",
  "to":      "<recipient-session-id>",   // only when --to was set
  "gap":     "<gap-id>",                  // when applicable
  "files":   "<comma-separated>",         // INTENT
  "reason":  "<text>",                    // STUCK / WARN / ALERT
  "commit":  "<sha>",                     // DONE
  "kind":    "<sub-type>",                // ALERT
  "model":   "<sender's model>",
  "harness": "<sender's harness>"
}
```

The same event is appended to **both** the recipient's inbox AND `.chump-locks/ambient.jsonl`. Ambient is the canonical audit trail; inbox is the per-recipient delivery channel. This is by-design redundancy — file audit always wins as the source of truth.

## Delivery semantics

| Property | Guarantee |
|---|---|
| At-least-once delivery | The sender's `broadcast.sh --to` always either writes both inbox + ambient, or writes ambient + emits a WARN to stderr. Inbox-write failure NEVER blocks ambient. |
| At-most-once | Not guaranteed at the protocol level. Recipients must de-dup by `(session, ts, gap, …)` if they care; in practice the inbox is append-once-per-call. |
| FIFO per sender → recipient | Yes. `flock` on the per-recipient lock file serializes appends. |
| Cross-sender ordering | Not guaranteed. Two senders writing concurrently may interleave by line, but each line is atomic. |
| Message TTL | None at v0. Layer 1a (INFRA-1118) adds a TTL reaper. Inboxes belonging to dead sessions get archived by the reaper. |
| Replay across restarts | Yes. Cursor file persists; recipient resumes from last offset. |

## Cursor semantics

- Default `--since` is `cursor`. The cursor file stores the byte offset that was read up to.
- `read` operations seek to `cursor + 1`, read to EOF, write the new cursor atomically via `mv tmp cursor`, and emit `inbox_advance`.
- `read --no-advance` reads from cursor but does NOT update; useful for previewing.
- `read --since all` ignores cursor; reads the whole file.
- `read --since <ISO-timestamp>` reads from offset 0 then filters in Python by `evt.ts >= since`. Slower for large inboxes but rarely needed.
- Cursor > file size triggers a soft-reset to 0 (file was archived/truncated).

## Glob recipient expansion

`broadcast.sh --to <pattern>` where `<pattern>` contains `*`, `?`, or `[…]` expands at send-time:

1. Walk `.chump-locks/*.json` (lease files).
2. Match each lease's basename against `<pattern>`.
3. Skip non-session lease files (`fleet-state.json`, `health-*.json`).
4. Write inbox event for each matching session.
5. If 0 matches, print WARN to stderr; ambient.jsonl still gets the event.

Expansion happens **server-side at send-time**, not recipient-side. A glob recipient is not preserved in the inbox event's `to:` field — the field carries the expanded session ID for each delivery.

## Concurrent-append safety

The sender's `emit_to_inbox`:

1. Opens `.<recipient>.lock` for write (creates if missing).
2. `flock -w 5 200` (5s wait).
3. On success: append the JSON line, release lock.
4. On flock timeout: emit `[broadcast] WARN: could not lock inbox ... within 5s` to stderr; ambient write still happens.

Stress-tested at 20 concurrent appenders → all lines land, all JSON-parseable.

When `flock(1)` is missing (rare on macOS without util-linux): falls through to best-effort `>>` append. Single-machine fleets with one process per session rarely race here.

## Reaper criteria

A session is "dead" iff:

1. Its lease file `.chump-locks/<session>.json` does not exist, **OR**
2. The lease's `expires_at` is in the past AND the elapsed-since-expiry exceeds `CHUMP_INBOX_REAP_GRACE_S` (default `3600` = 1h).

When dead AND the inbox file exists:

1. Decompress any existing `<archive-dir>/<yyyy-mm>.jsonl.gz`, append the live inbox, recompress.
2. Delete the live inbox file, cursor, and lock.
3. Emit `inbox_archived` to ambient with `{session, unread_messages, archive_path}`.

The reaper is idempotent and resumable: re-running with no changes is a no-op.

## Edge cases handled

| Case | Behavior |
|---|---|
| Empty inbox + `read` | Returns nothing (or `[]` in `--json` mode); cursor unchanged. |
| Sender's `--to` recipient has no lease file yet | Inbox file is created on first append; no error. |
| Recipient runs `read` while sender appending | flock serializes; reader sees a consistent file_size snapshot. |
| Killed reader mid-cursor-update | Tmp cursor remains; main cursor unchanged. Next read replays from old cursor (at-least-once). |
| Killed sender mid-append (under flock) | Partial line possible only if killed between `printf` start and the trailing newline; flock + append-mode + atomic write minimizes window. JSON-parse errors at reader are logged but don't crash. |
| Glob expansion matches 0 sessions | WARN to stderr, no inbox writes; ambient.jsonl preserves the event. |
| Cursor file corrupt (non-numeric) | Treated as 0; reader replays whole inbox. |
| Inbox file deleted while reader holds offset | Reader returns 0 messages; cursor file orphaned (cleaned by reaper). |
| Reader from a different working dir than sender | Both resolve `.chump-locks/` via git-common-dir; same physical path. |

## Edge cases NOT yet handled (deferred to v1+)

| Case | Plan |
|---|---|
| Message TTL within a live inbox | Add `CHUMP_INBOX_TTL_DAYS` daily-reaper hook. Defer to INFRA-1118 Layer 1a. |
| Inbox size cap | Track size, warn at 10k msgs, hard-cap at 100k. Defer. |
| Read receipts back to sender | Opt-in via `CHUMP_INBOX_RECEIPTS=1`; emit `inbox_read` with latency. Defer. |
| Multi-machine delivery | NATS-primary subscribe path. Layer 1a (INFRA-1118). |
| Reply / correlation_id propagation | New `--reply-to <correlation-id>` flag. Layer 2b (INFRA-1119) supersedes. |
| Schema versioning enforcement at reader | Add `schema_version` field, reader skips forward-incompatible. Defer to schema-evolution policy across Layers 2c/3d. |
| Operator dashboard pending-count column | `chump fleet-status` integration. Defer. |
| Mailbox auth (sender authentication) | Layer 4f signed provenance (INFRA-1123). |

## Performance budget

| Metric | Target | Measured |
|---|---|---|
| Inbox append latency (single-host) | < 5ms p99 | Not yet benched (low priority — flock+append is bounded) |
| Reader latency, 1k messages | < 50ms p99 | Not yet benched |
| Concurrent appenders before contention | ≥ 50 | Stress-tested 20 OK |

Once Layer 1a lands and pushes through NATS, the file write becomes the audit-write only; latency-critical path shifts to NATS. Bench tooling lands with INFRA-1118.

## Sunset criteria

The file-backed inbox sunsets when Layer 1a (INFRA-1118) NATS-primary delivery has been live for ≥ 90 days with `fleet_a2a_degraded` events = 0 across all production fleets. At that point:

- File inbox becomes **write-only audit** (sender still appends; reader subscribes to NATS instead).
- `chump-inbox.sh read` switches to NATS-tail with file as a fallback.
- The file is kept for forensics; the cursor/lock files retire.

## Migration path

INFRA-1115 ships as a **pure addition** — no flag day:

1. **Today (v0):** Existing `broadcast.sh` callers unchanged. New `--to` flag is opt-in.
2. **Tactical adoption:** INFRA-1117 (`chump pr nudge`) becomes the first heavy consumer.
3. **Layer 1a (INFRA-1118):** NATS subscriber composes with file inbox; readers prefer NATS, file is fallback.
4. **Sunset:** File inbox becomes audit-only after the 90-day NATS-primary run.

No version bump required to consume the new flag; agents on older chumps just ignore inbox files (their inbox stays unread; reaper archives eventually).

## Threat model (preview — full coverage in Layer 4f)

| Threat | v0 mitigation | v1 mitigation (Layer 4f) |
|---|---|---|
| Spoofed sender claiming `session: <victim>` | None at v0 — file inbox readable by all local sessions. | Signed envelope; verifier checks pubkey from manifest. |
| Inbox overflow flood from one sender | None at v0 — single sender can spam. Inbox-size cap (TTL) deferred. | Layer 4f revocation kills bad-actor key. |
| Cross-machine impersonation | N/A — v0 is single-host. | Trust-anchor signature requirement. |
| Replay of old messages | Reader sees them as new events (no de-dup). | Signed timestamps; reject events older than 5min. |

v0 explicitly assumes in-fleet trust (operator runs all sessions). Layer 4f closes the holes.

## Acceptance Criteria Flag (CREDIBLE-1270 / CREDIBLE-284 slice)

`chump gap reserve` accepts two flags governing acceptance-criteria capture on
new gaps:

- **`--acceptance-criteria <text>`** — supplies the gap's acceptance criteria
  verbatim at reserve time. The value is split on `|` into individual bullet
  items (e.g. `"bullet one|bullet two"` becomes two AC entries) and stored
  unmodified — no truncation, templating, or rewriting. Omitting this flag
  falls back to the INFRA-756 default obs-AC template (unless
  `--skip-obs-acs` is also passed).
- **`--no-ac-required`** — bypasses the enforcement below for a gap that
  genuinely has no meaningful AC yet (e.g. an exploratory P2/P3 spike). Use
  is audited: bypassing emits an `ac_gate_bypassed` event to
  `.chump-locks/ambient.jsonl` with the gap's priority, domain, and title.

**Enforcement rule.** A gap filed with `--priority P0` or `--priority P1`
that would otherwise end up with empty acceptance criteria (i.e.
`--skip-obs-acs` was passed and `--acceptance-criteria` was not) is rejected:
`chump gap reserve` prints an error to stderr and exits non-zero, unless
`--no-ac-required` is also supplied. P2/P3 gaps are never gated — the default
obs-AC template already fills acceptance criteria for the common path, so in
practice this gate fires only for P0/P1 gaps that explicitly opt out of the
template without supplying their own text.

Rationale: a P0/P1 gap with empty acceptance criteria is unpickable in
practice (`chump gap audit-priorities` already flags these as "vague
pickable" after the fact) — this flag closes the gate at file time instead
of catching it downstream.

## Open questions

- (MB-Q1) Should glob expansion include the trust-anchor signature check at send-time, or trust the operator-supplied pattern? Defer to Layer 4f.
- (MB-Q2) What's the right max-message-size? Today's events are < 1 KB; cap at 64 KB to allow attached patches in HANDOFF body? Defer.
- (MB-Q3) When a session has BOTH lease + heartbeat freshness checks failing, do we send to the inbox anyway or refuse with stderr warn? Today: send anyway (recipient may revive). Decision: keep current.

## See also

- [`A2A_MAILBOX.md`](../process/A2A_MAILBOX.md) — operator guide
- [`A2A_ROADMAP.md`](./A2A_ROADMAP.md) — context: mailbox is the tactical foundation for INFRA-1117 + Layer 1a
- [`broadcast.sh`](../../scripts/coord/broadcast.sh) source
- [`chump-inbox.sh`](../../scripts/coord/chump-inbox.sh) source
- [`inbox-reap.sh`](../../scripts/coord/inbox-reap.sh) source
- [`test-a2a-mailbox.sh`](../../scripts/ci/test-a2a-mailbox.sh) — 10-assertion test
