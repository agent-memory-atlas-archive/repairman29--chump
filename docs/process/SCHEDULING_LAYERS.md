---
doc_tag: canonical
owner_gap: DOC-058
last_audited: 2026-06-15
---

# Scheduling Layers — Session-Bound vs Fleet-Durable

> The single most common scheduling mistake in the Chump fleet: a curator
> arms a `CronCreate` or `ScheduleWakeup` to keep something running, closes
> their Claude Code session at end of day, and the scheduled work silently
> vanishes. The inverse also happens: a plist is written for an
> operator-driven `/loop` that should stop when the operator leaves — and
> the daemon keeps running against a dead session indefinitely.
>
> This doc fixes that by making the distinction explicit.

## TL;DR — decision table

| Intent | Layer | Why |
|---|---|---|
| "Poll the deploy every 5 min during this debugging session" | **Session-bound** (CronCreate or Monitor) | Dies with the session — that is correct here |
| "Rotate the OAuth token every 5 min forever" | **Fleet-durable** (launchd plist) | Must outlive any Claude session |
| "React when this log line appears in the next 2 hours" | **Session-bound** (Monitor) | Event-driven, tied to operator presence |
| "Prune orphan worktrees nightly" | **Fleet-durable** (launchd plist) | Housekeeping; should run even when no curator is active |
| "Check if my PR merged before I sign off" | **Session-bound** (ScheduleWakeup) | One-shot, operator-scoped, fine to die with session |
| "Run the gap-gardener daily sweep regardless of who is logged in" | **Fleet-durable** (launchd plist via `chump cron install`) | Work queue must not depend on a human being present |

**The rule (one question):** Will this still need to run after the operator
closes their Claude Code session at the end of the day?

- **Yes** → fleet-durable (launchd plist).
- **No** → session-bound (CronCreate / ScheduleWakeup / Monitor).

---

## The four scheduling surfaces

### 1. CronCreate (session-bound)

**What it is.** A Claude Code harness tool available inside a `/loop` or
`/schedule` invocation. Schedules a prompt to fire on a cron expression
(e.g., `*/10 * * * *`) within the running session's process tree. The
companion `CronDelete <id>` cancels it.

**Lifetime.** Dies when the Claude Code session exits — the prompt target
is the running conversation, which no longer exists once the session closes.
There is no persistence to disk.

**How to invoke.**

```
# Inside a Claude Code session running under /loop or /schedule:
CronCreate  every-10-min  */10 * * * *  "run the gap-picker cycle"
CronDelete  every-10-min
```

From CLAUDE.md (Pattern 15): when you are inside a `/loop`-armed cron,
**every cycle must produce a ship-class action**. When you genuinely shipped
nothing, stop the cron with `CronDelete <id>` rather than continue burning
tokens on no-ops.

**Gotchas.**

- Survives `chump gap ship`, PR creation, subagent dispatch — but **not**
  session close. Operators who rely on a CronCreate to keep a fleet process
  alive overnight will find it gone in the morning.
- Every CronCreate wake spawns a fresh Claude Code subprocess. State does
  **not** carry over between wakes. See
  [`CLAUDE_GOTCHAS.md`](./CLAUDE_GOTCHAS.md) "staleness layers" section —
  long-running cron loops drift from `origin/main`.
- Use `CronDelete` proactively on any cron that exists only to watch a
  single PR or event. Leaving it armed after the event resolves burns tokens
  on a dead target.

---

### 2. ScheduleWakeup (session-bound)

**What it is.** A Claude Code harness tool that fires a single future
prompt within the current dynamic-mode `/loop` session. Used instead of
CronCreate when the desired behavior is "wake me up once in N seconds, then
I'll decide whether to arm another."

**Lifetime.** Session-bound. One-shot. The wake fires within the running
session; if the session exits before the wake fires, the wake is lost.

**How to invoke** (from `docs/architecture/AGENT_LOOP.md`):

```
# After every gap ships OR after a queue-empty check:
ScheduleWakeup
  prompt: "You are a Chump agent on the autonomous work queue. Read
           docs/architecture/AGENT_LOOP.md and follow the loop instructions
           exactly. Start immediately — call ScheduleWakeup after each gap
           ships."
  delay_seconds: 1200
```

Prefer ScheduleWakeup over `Bash run_in_background` polling when you want
"check back later" semantics — the runtime notifies you when the delay
elapses; you don't have to poll.

**Gotchas.**

- ScheduleWakeup is not available outside `/loop` mode. If the agent
  reports the tool is unrecognized, fall back to the shell wrapper:
  `scripts/dev/agent-loop.sh`.
- Do NOT equate ScheduleWakeup with Cursor's headless `agent -p` — they
  have different automation and resume semantics. Only the coordination
  contract is shared. See `docs/architecture/AGENT_LOOP.md` for the
  comparison table.
- A ScheduleWakeup that fires into a dead session context is silently
  dropped. For anything that must survive a session close, use launchd.

---

### 3. Monitor (session-bound)

**What it is.** A Claude Code tool that streams stdout from a background
process or file tail into the running session. Useful for event-driven
reaction: "wake me when this log line appears," "notify when this CI check
completes."

**Lifetime.** Session-bound. The monitor process and its notifications exist
only as long as the session is running. When the session exits, the monitor
process is cleaned up.

**How to invoke.**

```bash
# Arm a monitor on ambient.jsonl from inside a /loop session:
# (the Monitor tool consumes this as its stream source)
Monitor  ambient-tail  tail -f .chump-locks/ambient.jsonl
```

**Gotchas.**

- Do NOT use Monitor as a replacement for fleet-durable watchers. The
  `com.chump.heartbeat-watcher.plist`, `com.chump.bot-merge-watchdog.plist`,
  and similar launchd daemons fill this role for processes that must
  outlive sessions.
- Polling `tail -f ambient.jsonl` in a busy script loop outside Monitor is
  an anti-pattern — use `chump-coord watch` for live tail or ScheduleWakeup
  for delayed wakes. Direct tail loops burn CPU and don't back-pressure.
- A Monitor armed in a `/loop` watching ambient is session-bound by design:
  it is correct for the operator-presence window. This is different from
  `com.chump.queue-health-monitor.plist`, which runs 24/7.

---

### 4. Fleet-durable (launchd plist via `chump cron`)

**What it is.** A macOS LaunchAgent plist installed under
`~/Library/LaunchAgents/` that launchd manages independently of any Claude
Code session. Survives operator logout, Claude restarts, machine sleep
(with `KeepAlive` or `StartInterval`). The Chump fleet has 23+ such daemons
catalogued in `launchd/` and `scripts/setup/`.

**Lifetime.** Durable. launchd keeps the agent alive according to the plist
configuration (`StartInterval`, `KeepAlive`, `StartCalendarInterval`). The
daemon only stops when the operator unloads it:

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.chump.NAME.plist
```

**Current fleet daemons** (examples from `launchd/`):

| Label | Cadence | Purpose |
|---|---|---|
| `com.chump.oauth-refresh` | 300s | Refreshes `~/.chump/oauth-token.json` from Keychain |
| `com.chump.gh-token-rotate` | — | GitHub token rotation |
| `com.chump.prune-worktrees` | — | Nightly worktree cleanup |
| `com.chump.heartbeat-watcher` | — | Detects silent agents |
| `com.chump.bot-merge-watchdog` | — | Unsticks wedged merges |
| `com.chump.reap-stale-leases` | — | Releases expired `.chump-locks/*.json` |
| `com.chump.queue-health-monitor` | — | Monitors gap-queue health |
| `com.chump.gap-curate` | — | Gap gardener / daily sweep |
| `com.chump.synthesis-pass` | — | Fleet synthesis routine |
| `com.chump.github-cache-reconcile` | — | Keeps `.chump/github_cache.db` fresh |
| `com.chump.api-cost-digest` | — | API cost reporting |
| `com.chump.fleet-daemon` | — | Main fleet worker daemon |

**How to install** (`chump cron install` — INFRA-2057/INFRA-2046):

```bash
# The canonical path (when INFRA-2057 ships):
chump cron install --label com.chump.my-daemon --script scripts/coord/my-daemon.sh \
  --interval 300

# List installed Chump plists and their health:
chump cron list
chump cron health     # exits non-zero if any plist lacks StartInterval (INFRA-1929 class)

# Delete:
chump cron delete <id>
```

Until `chump cron install` fully ships, install manually via
`scripts/setup/chump-fleet-bootstrap.sh` (which idempotently installs all
known plists) and `launchctl load`:

```bash
bash scripts/setup/chump-fleet-bootstrap.sh   # installs all known plists
launchctl load ~/Library/LaunchAgents/com.chump.NAME.plist
launchctl list | grep com.chump.NAME           # verify
```

**Gotchas.**

- A plist without `StartInterval` or `StartCalendarInterval` runs once at
  load and never again (INFRA-1929 failure class). `chump cron health`
  audits for this. Manual check:
  ```bash
  plutil -p ~/Library/LaunchAgents/com.chump.NAME.plist \
    | grep -E 'StartInterval|StartCalendarInterval'
  ```
- A plist whose backing script depends on a specific Claude agent session
  being alive will silently fail when that session ends. Example: a plist
  that calls `claude -p "..." --session <id>` to wake a specific session —
  when that session closes, every invocation returns "session not found"
  and launchd just keeps retrying. Fix: make the backing script
  session-independent (spawn a fresh `claude -p` without a session ID) or
  use a session-bound Monitor instead.
- **Operator-action required** for new plists. `chump-fleet-bootstrap.sh`
  will not automatically load newly added plists in a running system.
  After adding a plist to `launchd/`, the operator must run:
  ```bash
  launchctl load ~/Library/LaunchAgents/com.chump.NEW-NAME.plist
  ```
- New daemon shipped but operator hasn't reloaded = drift (freshness layer
  4 per `docs/process/FRESHNESS_DISCIPLINE.md`). `chump cron health`
  (INFRA-2046) catches this.
- **Legacy-label orphan plists (split-brain footgun, RESILIENT-120).** The
  canonical durable `/loop` scheduler is **`chump fleet autopilot`** plus
  **`com.chump.wizard-daemon`** — the launchd label prefix is `com.chump.*`.
  Older installers used an `ai.chump.*` prefix; a renamed daemon can leave an
  `ai.chump.NAME.plist` orphan on disk that no repo installer references.
  It is dangerous *even while unloaded*: if it is ever loaded it **double-ticks
  at a stale interval running a divergent script** (the `ai.chump.wizard-daemon`
  orphan ticked at 180s and ran `origin/main`'s `wizard-daemon.sh` vs the
  canonical 300s local one). `install-wizard-daemon-launchd.sh` now purges the
  legacy `ai.chump.wizard-daemon.plist` on every install **and** uninstall;
  re-run it to self-heal a split-brain machine. Audit:
  ```bash
  ls ~/Library/LaunchAgents | grep -c 'chump.wizard-daemon'   # must be 1 (com.chump only)
  chump fleet autopilot status                                # loaded == configured, ticking
  ```

---

## The rule — expanded

> **Will this still need to run after the operator closes their Claude Code
> session at the end of the day?**
>
> - **Yes** → fleet-durable (launchd plist).
> - **No** → session-bound (CronCreate / ScheduleWakeup / Monitor).

The right framing is operator-presence. The session-bound layer exists
exclusively within an operator window — when the operator is present and
attentive, running Claude Code. It is the correct layer for:

- Watching a single PR as it races through CI
- Polling a deploy while you're actively debugging it
- Reacting to a specific event in the next hour or two

The fleet-durable layer runs whether or not any operator or curator is
present. It is the correct layer for:

- Token refresh (must not lapse while a worker is mid-task)
- Nightly maintenance (pruning, GC, synthesis passes)
- Fleet health monitoring (heartbeat, wedge detection, queue health)
- Any recurring work that backs the fleet's reliability guarantees

---

## Decision table — six canonical cases (AC row 2)

| Scenario | Layer | Rationale |
|---|---|---|
| Shepherd `/loop` while operator window open | **Session-bound** (ScheduleWakeup after each gap) | Operator is present; session dying = shepherd done, correct |
| Gap-gardener daily sweep | **Fleet-durable** (`com.chump.gap-curate.plist`) | Must run at 2 AM when no one is logged in |
| `pr-rescue` daemon | **Fleet-durable** (`com.chump.bot-merge-watchdog.plist`) | PRs don't pause because the operator went to bed |
| Operator-driven `/schedule` cron (CronCreate) | **Session-bound** | Operator-scoped by design; ends with their window |
| Wedge-state-machine reaper | **Fleet-durable** (`com.chump.reap-stale-leases.plist`) | Stale leases accumulate; reaper runs continuously |
| Monitor armed in `/loop` watching ambient | **Session-bound** | Correct for the operator-presence window; launchd equivalent watches 24/7 |

---

## Migration guide — CronCreate to `chump cron install`

If you have a recurring task currently managed via `CronCreate` that needs
to outlive the session, follow these steps:

1. **Extract the script** from the cron prompt into a standalone shell
   script (e.g., `scripts/coord/my-recurring-task.sh`). The script must
   be session-independent — no Claude session ID, no session-local context.

2. **Validate the script runs headlessly:**
   ```bash
   bash scripts/coord/my-recurring-task.sh
   echo "exit: $?"
   ```

3. **Create the plist** (copy from an existing example as template):
   ```bash
   cp launchd/com.chump.prune-worktrees.plist launchd/com.chump.my-task.plist
   # Edit: Label, ProgramArguments, StartInterval, description comment
   ```

4. **Install and verify:**
   ```bash
   cp launchd/com.chump.my-task.plist ~/Library/LaunchAgents/
   launchctl load ~/Library/LaunchAgents/com.chump.my-task.plist
   launchctl list | grep com.chump.my-task
   chump cron health      # confirm no StartInterval-missing error
   ```

5. **Cancel the CronCreate** from the running session:
   ```bash
   CronDelete <cron-id>
   ```

6. **Add to `chump-fleet-bootstrap.sh`** so the plist installs on next
   bootstrap for all operators.

---

## Anti-patterns

### Anti-pattern A: CronCreate for fleet-durable work

**Symptom.** An Opus curator arms a CronCreate to keep a recurring sweep
running. The operator closes their Claude Code session at end of day. The
next morning the sweep is gone — no heartbeat, no output, no error.

**Real-world trigger.** Operator complaint 2026-05-29: "scheduled-task cron
stopped working overnight." Root cause: the task was session-bound via
CronCreate; session died; task vanished.

**Diagnosis.** Ask: does this task need to run when no Claude session is
open? If yes, it should be a plist.

**Fix.** Follow the migration guide above. Write a headless script; add a
plist; install via `chump-fleet-bootstrap.sh`.

---

### Anti-pattern B: launchd plist for an operator-driven loop

**Symptom.** An operator writes a plist to run a script that calls
`claude -p` with a specific session-continuation prompt. The session ends
naturally. launchd keeps firing; each invocation produces "session not
found" and either exits with an error or spins a new session the operator
doesn't know about.

**Fix.** Remove the plist (`launchctl bootout ... && rm ~/Library/LaunchAgents/...`).
Replace with a ScheduleWakeup loop inside the active session, or a
session-independent `scripts/dev/agent-loop.sh` invocation that doesn't
depend on a prior session being alive.

---

### Anti-pattern C: plist without `StartInterval` (INFRA-1929 class)

**Symptom.** New plist ships, is loaded, fires once at load, then never runs
again. No error in launchd logs. Operator assumes the daemon is running.

**Diagnosis.**
```bash
plutil -p ~/Library/LaunchAgents/com.chump.NAME.plist \
  | grep -E 'StartInterval|StartCalendarInterval'
# Returns nothing → plist will only fire once.
```

**Fix.** Add `<key>StartInterval</key><integer>N</integer>` to the plist
(N = seconds between invocations). Reload:
```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.chump.NAME.plist
launchctl load ~/Library/LaunchAgents/com.chump.NAME.plist
```

`chump cron health` (INFRA-2046) detects this class automatically.

---

### Anti-pattern D: plist whose script depends on a live agent session

**Symptom.** `launchd/com.chump.example.plist` runs a script that does:
```bash
claude -p "check PR status" --session $(cat /tmp/current-session-id)
```
Session ID is written by the operator's running Claude Code session. When
the session exits, `/tmp/current-session-id` goes stale. The plist keeps
firing; every invocation errors; launchd backs off but keeps retrying.

**Fix.** Make the backing script session-independent. Use
`claude -p "..."` without `--session` to start a fresh context, OR use a
fleet-side coordination tool (`chump gap list`, `gh pr view`, etc.) that
doesn't require a Claude session at all.

---

### Anti-pattern E: polling with CronCreate when Monitor would be evented

**Symptom.** A CronCreate fires every 30 seconds to run `gh pr checks <N>`
and check if a PR has merged. This burns ~200 output tokens per poll,
exhausts the secondary-rate-limit bucket faster than necessary, and only
detects events up to 30s late.

**Fix.** Use Monitor on the webhook-populated cache (`.chump/github_cache.db`)
or on ambient.jsonl for event-driven detection. If the check is not time-critical,
use a single ScheduleWakeup 5-10 minutes out instead of a recurring cron.

---

## Worked example — diagnosing and fixing a scheduling mistake

**Operator complaint (2026-05-29):** "Claude Code scheduled-task cron is
throwing error noise and not running my sweep."

**Step 1 — identify which layer was used.**
```bash
# In the Claude Code session: list active crons
# (output appears in the session tool output)
# Also check: was this set up via /schedule or /loop?
```

If the session shows the cron was armed via `CronCreate` but the operator
expected it to persist overnight → the wrong layer was used.

**Step 2 — check if a plist exists.**
```bash
ls ~/Library/LaunchAgents/com.chump.*.plist
launchctl list | grep com.chump
```

If no matching plist exists → the work was only session-bound.

**Step 3 — choose the fix.**

- If the sweep needs to run overnight: extract it to a script, write a
  plist, install via bootstrap (migration guide above).
- If the sweep is operator-session-scoped and was just expected to survive
  a session close: accept the session-bound semantics. Re-arm via
  `CronCreate` or ScheduleWakeup at session start.

**Step 4 — verify after fix.**
```bash
chump cron health                          # no missing-StartInterval errors
launchctl list | grep com.chump.my-task   # shows PID if currently running
tail -20 /tmp/chump-my-task.out.log       # recent output
```

---

## Dynamic-mode `/loop` best practice (DOC-066, 2026-06-05)

> One concrete failure mode the canonical layers above don't quite cover:
> an operator-presence loop that **silently dies** because the agent
> chose a fragile chaining pattern.

The `/loop` skill has two modes per its spec:

- **Fixed-interval** (e.g., `/loop 5m <prompt>`) → CronCreate, recurring,
  fires every N min while session is alive.
- **Dynamic-mode** (no interval, just `/loop <prompt>`) → ScheduleWakeup,
  one-shot, self-pacing. **Each tick must re-arm ScheduleWakeup** or the
  loop dies after the next fire.

**The fragile pattern (don't do this for long-running operator loops):**

```
operator → /loop <prompt>
agent → does work + arms Monitor + calls ScheduleWakeup(1500s, prompt)
        → harness re-invokes at deadline
agent → ... → forgets to re-arm OR crashes mid-tick OR drifts off-script
        → loop dies silently. Operator thinks it's still running.
```

This is the **"reporting a mechanism as active before verifying it is
active"** band-aid family in `DURABLE_FIX_DOCTRINE.md` — pointed at status
instead of code.

### The durable pattern (recurring CronCreate + persistent Monitor hybrid)

For any operator-presence loop that must keep firing across many ticks
without depending on the agent re-arming each time:

```
1. CronCreate with recurring=true → fires every N min on its own
   (the harness re-arms — agent failure doesn't stop the next tick).
2. Persistent Monitor on .chump-locks/ambient.jsonl filtered for
   halt-class events → wakes immediately on real problems, independent
   of the cron schedule.
3. Each cron tick prompt is FIRE-AND-FORGET:
   - one pulse (cache-first SQL reads, < 1s)
   - one ship-class action (claim/close/dispatch/file/release)
   - then RETURN. NO merge-watch Monitors. NO Bash run_in_background polls.
   Let the auto-merge daemon land PRs in the background; the next tick
   observes the merged result.
```

### Why each piece is required

| Component | Solves |
|---|---|
| `CronCreate recurring=true` | Survives agent failure within a session. Harness re-arms. |
| `Monitor` on ambient.jsonl | Event-driven wake on real halt-class signals (faster than waiting for the next cron tick). |
| No merge-watch Monitors | Each merge-watch pins the REPL non-idle, starving the cron of fire windows. |
| Fire-and-forget tick body | Lets the cron complete in < 2 min so the next tick has space. |

### Halt-class Monitor filter

Filter `tail -F .chump-locks/ambient.jsonl` for kinds that warrant immediate
wake. Exclude known false-positive classes that haven't been substrate-fixed
yet (cross-ref the case study in `DURABLE_FIX_DOCTRINE.md` and any open
`*_false_positive` gaps):

```bash
# 2026-06-05 example. After RESILIENT-113 lands, AUTH_DEAD becomes
# legitimately halt-class again because farmer.sh no longer false-positives.
tail -F .chump-locks/ambient.jsonl \
  | grep --line-buffered -E '"kind":"(fleet_wedge|disk_critical|trunk_red|silent_agent|pr_stuck|farmer_auth_dead)"' \
  | grep --line-buffered -v "AUTH_DEAD"   # remove once #3090 in main
```

### Verifying the loop is actually live (not just claimed-live)

Per `DURABLE_FIX_DOCTRINE.md`: don't report a mechanism as active before
verifying. For session-bound loops:

```bash
# 1. Cron job armed?
# (in Claude Code session) CronList — shows job ID + schedule
# 2. Monitor armed?
# (in Claude Code session) TaskList (if available) — shows persistent Monitor
# 3. Empirical proof: do nothing for one cron interval + 30s.
#    If a tick report arrives unprompted, the loop is firing.
#    If nothing arrives, the loop is NOT firing (most likely cause:
#    REPL non-idle on cron boundaries — kill any blocking Monitor/Agent).
```

The `4 minutes` cadence on a recurring CronCreate has a Claude Code
limitation: jobs **only fire while the REPL is idle.** Long Sonnet
dispatches and merge-watch Monitors prevent fires. The fire-and-forget
discipline above is what unblocks the cron in practice.

### When to NOT use a session loop at all

If the work needs to run after the operator closes the session →
fleet-durable launchd plist per the layer table above. Don't try to keep a
session loop alive overnight — that's the inverse failure of this section.

---

## Cross-links

- **CLAUDE.md** — "No idle curators in loops (Pattern 15)" documents
  CronCreate / ScheduleWakeup discipline; this doc extends that with the
  fleet-durable alternative.
- **AGENTS.md** — §"Communication channels" covers ambient.jsonl, inbox
  DMs, and NATS broadcasts; scheduling is the complement (when to fire
  things, not where to route them).
- **`launchd/`** — fleet daemon plist catalog (23 daemons as of 2026-05-29).
- **`scripts/setup/chump-fleet-bootstrap.sh`** — installs all known plists;
  run `--check` to verify without installing.
- **`docs/process/FRESHNESS_DISCIPLINE.md`** — covers launchd plist drift
  as freshness layer 4; `chump cron health` is the audit tool.
- **`docs/architecture/AGENT_LOOP.md`** — canonical ScheduleWakeup usage
  pattern for autonomous queue workers.
- **INFRA-2057** — `chump cron install` subcommand (in-flight).
- **INFRA-2046** — `chump cron health` subcommand (in-flight).
