---
doc_tag: canonical
owner_gap: META-830
parent_gap: META-110
last_audited: 2026-09-18
---

# Chump-Native Scheduling Cluster — Umbrella Specification

> Design slice of META-110 (chump-native fleet scheduling primitives),
> filed as META-701 → sliced as META-830. This document is the
> specification artifact required by META-830's acceptance criteria; it
> does not ship new code — `chump cron` (crate: `chump-cron`) already
> exists and implements most of the surface described below. This doc
> makes the governing rule explicit, names the CLI/health/telemetry
> contract the implementation is held to, and records stakeholder
> sign-off.

## 1. The rule (AC1)

> **Any task whose correctness depends on persisting across agent-session
> restarts MUST be managed by chump-cron (launchd/systemd-backed), not by
> session-bound scheduling (`CronCreate` / `ScheduleWakeup` / `Monitor`).**

Session-bound scheduling is scoped to the lifetime of the Claude Code
process that armed it — it is the correct tool exactly when the work
should die with the session (an operator watching a single PR through
CI, a `/loop` window bounded by operator presence). The moment a task's
correctness depends on running *after* the session that created it has
exited, it has crossed into fleet-durable territory and must be backed
by a `chump cron`-managed launchd (macOS) or systemd (Linux) unit.

This rule is not new policy — it is the codification of
[`docs/process/SCHEDULING_LAYERS.md`](../process/SCHEDULING_LAYERS.md)
(DOC-058), which already carries the full decision table, anti-pattern
catalog, and migration guide. This spec exists so the rule has a single
canonical statement that a CLI surface, health check, and telemetry
schema can be normatively bound to (below), rather than living only as
prose guidance.

## 2. CLI surface (AC2a)

Canonical entry point: `chump cron <subcommand>`, implemented by the
`chump-cron` crate (`crates/chump-cron/src/{lib,ops,spec,backend,health_sentinel}.rs`).

| Subcommand | Contract |
|---|---|
| `chump cron install --label <com.chump.NAME> --script <path> --interval <secs>` | Declaratively installs a backend-native scheduled unit (launchd plist on macOS) for `script`, firing every `interval` seconds. Idempotent — re-running with identical args is a no-op; changed args update the unit in place. Must set `StartInterval` (or the systemd-timer equivalent) so the INFRA-1929 fire-once-then-never-again class is structurally unreachable through this path. |
| `chump cron uninstall --label <com.chump.NAME>` | Unloads and removes the unit. Idempotent on an already-absent label. |
| `chump cron list [--json]` | Enumerates every chump-cron-managed unit: label, script path, interval, loaded/unloaded state. `--json` for machine consumption by curators/dashboards. |
| `chump cron health [--json]` | Runs the invariant sweep (§3) across every managed unit and exits non-zero if any invariant fails. This is the subcommand referenced throughout `SCHEDULING_LAYERS.md` and is the audit primitive other curators (`infra-watcher`, `fleet-doctor`) call rather than re-implementing plist parsing themselves. |
| `chump cron delete <id>` | Alias for `uninstall` keyed by unit id rather than label, for scripted cleanup flows. |

**Non-goals of the CLI surface:** `chump cron` does not manage
session-bound scheduling (`CronCreate`/`ScheduleWakeup`/`Monitor` remain
Claude-Code-harness-only tools, out of `chump cron`'s scope by design —
see §1), and it does not itself decide *whether* a given task belongs on
this layer; that judgment call is the decision table in
`SCHEDULING_LAYERS.md` §"Decision table — six canonical cases".

## 3. Health visibility requirements (AC2b)

`chump cron health` (and any dashboard/curator surface built on top of
it) MUST detect, per managed unit, at minimum:

1. **Missing interval trigger** (INFRA-1929 class) — a unit with neither
   `StartInterval` nor `StartCalendarInterval` set, which fires once at
   load and never again. Detected by parsing the installed plist/timer
   and asserting one of the two keys is present and non-zero.
2. **Installed-but-unloaded drift** — a unit exists on disk
   (`~/Library/LaunchAgents/com.chump.*.plist`) but is not in
   `launchctl list` output. This is the exact failure mode that let the
   OAuth refresher go stale for 16 days (INFRA-1865) despite the plist
   being present.
3. **Legacy-label orphans** (RESILIENT-120 class) — a stale
   `ai.chump.*`-prefixed unit shadowing the canonical `com.chump.*`
   label for the same daemon. Health check surfaces these as a named
   finding, not a silent pass.
4. **Session-dependent backing script** — best-effort static check for
   scripts that shell out to `claude -p ... --session <id>` from within
   a fleet-durable unit (anti-pattern D). Full semantic detection is out
   of scope; a grep-level heuristic with a documented false-negative
   rate is acceptable for v1.

Exit code contract: `0` = all managed units pass all checks; non-zero =
at least one finding, with `--json` emitting a structured list of
`{label, check, status, detail}` so callers (fleet-doctor, infra-watcher)
can aggregate without re-parsing human-readable text.

## 4. Telemetry emission format (AC2b)

Every state-changing `chump cron` operation emits one `ambient.jsonl`
event, matching the existing ambient event conventions
(`docs/process/CLAUDE_GOTCHAS.md` event-kind guide):

```json
{"ts":"<ISO8601 UTC>","kind":"chump_cron_managed","label":"com.chump.NAME","action":"install|uninstall|health_check","interval_s":300,"status":"ok|missing_interval|unloaded|legacy_orphan"}
```

Field contract:

- `kind` — always `chump_cron_managed` (reserved in the ambient event
  registry; this is the single kind covering the whole cluster rather
  than one-kind-per-verb, keeping the registry from fragmenting).
- `action` — one of `install`, `uninstall`, `health_check`. Distinguishes
  a mutating call from a read-only audit tick in the same stream.
- `status` — `ok` for install/uninstall success; for `health_check`,
  one of the finding types in §3 (`missing_interval`, `unloaded`,
  `legacy_orphan`, `session_dependent`, or `ok`).
- `interval_s` — present on `install`/`health_check` for units that have
  one; omitted for `uninstall`.

This event is what closes the loop for META-110's umbrella acceptance
criterion "(e) ambient emit `kind=chump_cron_managed` appears for every
plist under chump cron management" — any unit installed via `chump cron
install` is, by construction, emitting this event, so an operator or
curator can answer "is this daemon chump-cron-managed?" by grepping
`ambient.jsonl` instead of manually enumerating `~/Library/LaunchAgents`.

## 5. Relationship to existing work

This spec does not introduce new mechanism. It is the documentation
artifact that:

- Names the CLI/health/telemetry contract the already-shipped
  `chump-cron` crate (INFRA-2057, INFRA-2046) is held to.
- Cross-links and does not duplicate `docs/process/SCHEDULING_LAYERS.md`
  (DOC-058), which remains the canonical decision-table + migration-guide
  + anti-pattern reference. This doc is the narrower "what MUST the
  cluster's surface look like" spec; `SCHEDULING_LAYERS.md` is the wider
  "how do I decide + migrate" guide.
- Feeds back into META-110's own acceptance criteria as the design
  record for its umbrella scope.

## 6. Stakeholder review sign-off (AC3)

| Reviewer | Role | Verdict | Date |
|---|---|---|---|
| Jeff Adkins | Operator | Approved — rule statement in §1 matches the 2026-05-27 discovery context and DOC-058 intent; CLI/health/telemetry contract in §2-4 matches the already-shipped `chump-cron` crate surface with no scope additions required | 2026-09-18 |

Sign-off recorded via this table per META-830 AC3. No further review
gate is required to close this design slice; implementation-level
changes to `chump-cron` continue to ship as their own gaps (tracked
under the META-110 umbrella) and are reviewed through the normal PR
process.
