# One-command install: bill-of-materials, rootless placement, bring-up staging

Design note for INFRA-3867 ("Ribbon: a bare box becomes a real ChumpOS node in
one command"). North star: someone gets a new machine, sees one command, runs
it — sovereign, on owned iron, zero-touch, no sudo. This doc resolves the
three findings from the read-only fresh-box assessment and gives the ordered
slices that implement them. **The rootless decision is already made and is
out of scope here**: placement is `systemd --user` + `loginctl enable-linger`
(Linux), the equivalent for `runit` (Termux) and `launchd` (macOS) — never a
sudo step. This doc designs *how*, not *whether*.

## 0. What's broken today (verified, not assumed)

Read directly from `scripts/setup/chump-node-install.sh`,
`scripts/ops/organ-manifest.txt`, `scripts/setup/bootstrap-manifest.yaml`,
`scripts/setup/install-node-housekeeping.sh`, and `scripts/ops/node-orchestrator.sh`
on 2026-09-19:

1. **`place_role_unit_files()`** (chump-node-install.sh:943) checks `id -u`
   (line 954) and, when not root, calls `bootstrap_organ_deploy_via_sudo()`
   (a sudo-or-skip fallback) and then **returns without placing anything**.
   A fresh non-root box converges 3 of ~40 organs (heartbeat, worker,
   process-organ-heal) — none of the brain plane.
2. **`svc_install()`/`svc_up()`/`svc_down()`** (chump-node-install.sh:133-186)
   — the "reusable supervisor abstraction" used for the common/muscle organ
   set — is *worse*: its `systemd` branch unconditionally
   `cat > /etc/systemd/system/chump-$name.service` with **no root check at
   all**. On a non-root box this fails silently (`run`'s `eval` has no error
   path here, and `svc_up`'s `systemctl enable --now ... 2>/dev/null || true`
   swallows the failure). Any rootless fix must cover **both** placement
   paths — they are not one function, they are two independent root-only
   write sites.
3. **A third, unmanifested roster.** `scripts/setup/install-node-housekeeping.sh`
   installs its own hardcoded 10-organ list (`node-orchestrator`, `rot-reaper`,
   `worktree-reaper`, `disk-monitor`, `main-health-watchdog`, `pr-lander`,
   `cargo-sweep-gc`, `reviver`, `pr-stuck-live-scan`, `pr-stuck-cluster-detector`)
   via `sudo tee /etc/systemd/system/chump-$name.service` (its own line 65) —
   a THIRD root-gated installer, disjoint from `organ-manifest.txt` (most of
   these names don't appear there verbatim) and disjoint from
   `bootstrap-manifest.yaml`. **`node-orchestrator.sh` — the one thing that
   enforces the cargo-jobs cap — only ever gets installed through this
   sudo-gated script.** On a fresh non-root box it never runs, so
   `enforce_cargo_jobs()` never fires, at any point, ever — this is the real
   root cause behind finding 3, not just a launch-order race.
4. **No union between the two named rosters.** `organ-manifest.txt` (Linux,
   ~40 organs, `role=brain|data|janitor|muscle|trust`) and
   `bootstrap-manifest.yaml` (macOS, ~31 installer `id`s) don't reference each
   other. Tracing `ExecStart=`/`install:` back to the underlying script for
   the ambiguous names resolves most of them:

   | macOS-only capability (bootstrap-manifest.yaml) | Underlying script | Linux equivalent? |
   |---|---|---|
   | `curator-launchd` (P0 demotion, vague-AC fill, pillar rebalance) | `scripts/coord/opus-curator.sh` | **None.** `chump-rca-reflex.service` runs `recurring-gap-pattern-detector.sh`; `chump-gap-drain.service` runs `gap-drain.sh`. Neither is opus-curator. Genuinely absent on Linux. |
   | `self-doctor-launchd` (`fleet doctor --heal` every 5 min) | `install-self-doctor.sh` | **None confirmed.** `chump-process-organ-heal.service` runs `process-organ-heal.sh` (heals organ *processes*, not gap-dispatch via fleet doctor). Different capability. |
   | `paramedic-launchd` (PR rescue every 10 min) | `install-paramedic.sh` | **None** — no PR-rescue timer in organ-manifest.txt (shepherd is an agent role, not a systemd unit). |
   | `conductor-launchd` (self-rescue consensus proposal, 30 min) | `install-conductor-launchd.sh` | **None** — closest is `chump-organ-success-verifier`/`chump-effect-verifier`, which verify effects, not propose self-rescue. Different capability. |
   | `github-liaison-launchd`, `quartermaster-audit-launchd`, `ghost-pr-closer-launchd`, `trunk-sentinel-launchd`, `pr-shepherd-daemon-launchd` | (not yet traced individually) | Not found by name or obvious script match in organ-manifest.txt or scripts/dispatch/*.service — treat as **absent on Linux** until slice A's audit proves otherwise. |
   | `auto-deploy-launchd` | `scripts/ops/auto-deploy.sh` | **Distinct from** `chump-organ-deploy.timer` (name-similar, wrong script — organ-deploy places unit files, auto-deploy.sh does something else). Not a match. |
   | `fleet-server-launchd` | — | **Exact match**: `chump-fleet-server.service` exists in `scripts/dispatch/`. Same capability, different manifest, needs union not reconciliation. |
   | `almanac-code-intel` | — | Close to `chump-almanac-liveness.timer`, likely the same eyes organ under a different id — confirm in slice A. |

   Conclusion: most of the "same capability, different name" cases turned out
   to be **genuinely absent on Linux**, not just renamed. That changes the
   shape of unification — it's not a pure rename-and-merge, it's rename-merge
   for the ~3-4 confirmed matches (`fleet-server`, `almanac-code-intel`,
   possibly `chump-planner-launchd`↔a data organ) plus an honest "Linux gap"
   list for the rest, which becomes backlog under the SAME roster rather than
   silently-missing.

5. **No job cap during bring-up.** Neither `refresh-runner-binary.sh`
   (backs the chump build) nor `install-almanac.sh` (backs the almanac build,
   invoked async via `ensure_eyes` → `install-almanac-organ.sh`) sets `nice`,
   `ionice`, or `CARGO_BUILD_JOBS`. `ensure_substrate` and `ensure_eyes` are
   both launched back-to-back via `run_phase_async` (chump-node-install.sh:1575-1576)
   and both `disown` — they outlive the installer and can overlap each other,
   and outlive a SINGLE run to overlap a retried run's own synchronous chump
   build. Finding 1 and finding 3 are the same disease: the daemon that would
   have prevented the overlap (`node-orchestrator.sh`) is itself blocked by
   the same root gate as the rest of the brain plane (see point 3).

## 1. Unified, platform-neutral bill-of-materials

**One declared roster, in the repo, that every supervisor renders from** —
not three. Extend `scripts/ops/organ-manifest.txt`'s existing schema (it
already has the right shape: `role=`, `requires=`) with a `platforms=` field:

```
enabled  chump-almanac-liveness.timer  role=data requires=bin:git  platforms=systemd,launchd,runit
enabled  chump-opus-curator.timer      role=brain requires=bin:chump  platforms=launchd   # Linux equivalent: TODO, tracked as backlog under this same line
```

- Default `platforms=systemd` (today's implicit assumption) so nothing
  regresses when the field is omitted.
- Every macOS-only capability from `bootstrap-manifest.yaml` gets ONE line
  here, `platforms=launchd`, even when no Linux port exists yet — this makes
  the Linux gap **visible in the single source of truth** instead of living
  only in a second file nobody diffs against the first.
- `bootstrap-manifest.yaml`'s `id:` becomes a pointer into this manifest
  (`organ: chump-opus-curator`) instead of an independent installer
  description, for every id that has (or gets) a manifest line. Ids that are
  pure one-time setup (`chump-binary`, `git-hooks`) are NOT organs and stay
  out of the manifest — they're prerequisites, not supervised services.
- `install-node-housekeeping.sh`'s 10-organ hardcoded list gets folded into
  the SAME manifest with real `role=` tags (node-orchestrator=brain,
  rot-reaper/worktree-reaper/cargo-sweep-gc=janitor, pr-lander/reviver=brain,
  disk-monitor=janitor, main-health-watchdog=brain, pr-stuck-*=brain) and
  the script itself is reduced to a thin caller of the same placement path
  slice B builds — no more independent `sudo tee`.
- One renderer per supervisor (systemd --user unit / runit service dir /
  launchd plist) reads the SAME manifest and SAME `role=`/`platforms=`
  filter — this is what `organ_unit_host_rewrite` already half-does for
  systemd; slice A only unions the DATA, slice B teaches the renderer to
  also target `--user` scope and the other two supervisors.

This is pure data + audit work — **zero behavior change**, so it can land
first and safely, and gives B a single source instead of three to render
from.

## 2. Rootless placement: `--user` + linger, for both placement paths

Two write sites need the same fix, not one:

### a. `place_role_unit_files()` (the manifest-driven placer)

Replace the `id -u != 0` skip with a `--user`-scope branch, unconditionally
preferred:

- Unit dest becomes `${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/` instead
  of `/etc/systemd/system`.
- `organ_unit_host_rewrite()` (scripts/ops/lib/organ-unit-install-lib.sh)
  gains a `user_scope` mode: strip `User=`/`Group=` entirely (a `--user` unit
  always runs as the invoking user — that's the whole point), drop
  `WantedBy=multi-user.target` in favor of `WantedBy=default.target`, and
  keep the existing HOME/repo-path rewrite logic untouched (it's already
  host-agnostic, RESILIENT-1102's fix generalizes for free).
- `systemctl daemon-reload` → `systemctl --user daemon-reload`;
  `systemctl enable --now` → `systemctl --user enable --now`.
- One new step, once per node, idempotent: `loginctl enable-linger "$(whoami)"`
  — required so `--user` units keep running after the install SSH session
  ends and across reboots without an active login. `install-fleet-health-sentinel.sh`
  already does exactly this (line 76-79) with a graceful fallback message —
  reuse that pattern verbatim rather than re-inventing it.
- `chump-organ-deploy.service/.timer` — the one privileged-by-design pair
  that runs the root reconcile cycle (`_KEEP_ROOT` in
  `place_role_unit_files()`) — is the ONE unit that legitimately still wants
  a root path *if root is available*. On a rootless box it simply doesn't
  exist; the `--user` `chump-organ-reconcile.timer` (already `role`-scoped
  per node, RESILIENT-1055) becomes the sole self-heal beat. No unit is
  "half-placed" — the root path is additive when root exists, never required.
- Delete (or reduce to a one-line delegator) `bootstrap_organ_deploy_via_sudo()`
  — its entire job (bootstrap a self-heal timer when root isn't available at
  install time) is subsumed by "just place `--user` units, they don't need
  root to begin with."

### b. `svc_install()`/`svc_up()`/`svc_down()`/`svc_status()` (the common/muscle path)

Same fix, smaller surface: the `systemd)` case branches on
`[ "$(id -u)" = 0 ]` and either writes `/etc/systemd/system/chump-$name.service`
+ `systemctl ...` (root) or `$HOME/.config/systemd/user/chump-$name.service`
+ `systemctl --user ...` (default). Today this function has **zero** root
awareness, which is a silent-failure bug independent of the "root gate"
policy question — fixing it is not optional cleanup, it's a correctness bug
in the path that installs the 3 organs that DO converge today.

### c. Role-gating without root

Nothing changes here — `organ_role_filter()` and the `role=` tags in the
manifest are supervisor-agnostic already; they decide *which* units get
rendered, not *how* they're placed. A `--role brain` fresh install places
the brain-tagged subset as `--user` units exactly as it places the muscle
subset today, just at a different destination path.

### d. How the 3 existing supervisors already prove this works

`install-almanac-organ.sh`, `install-oauth-refresh-systemd.sh`, and
`install-fleet-health-sentinel.sh` are ALL already `systemd --user` +
`loginctl enable-linger` today — this is not a novel mechanism, it's a
proven pattern used by three single-organ installers that never got
generalized to the manifest-driven placer or to `svc_install`. Slice B is
"promote the pattern these three already use to the two placement functions
that matter for the other 37 organs," not "invent rootless systemd."

## 3. Bring-up build staging

1. **Prebuilt-first stays the default** — `ensure_binary()`'s ladder
   (provenance-verified `$BIN` → CI-artifact fetch → release tarball →
   source build) already puts the network fetch paths ahead of
   `build_binary_from_repo()`. No change needed here; this section only
   covers what happens when the fallback fires.
2. **Start the cap-enforcer before any build, not after role convergence.**
   Once slice B lands, `node-orchestrator.sh` is placeable as a rootless
   `--user` unit. Move its placement (or at minimum a one-shot
   `node-orchestrator.sh --enforce-once`, a new small mode that runs
   `sense` + `enforce_cargo_jobs` once and exits — no daemon loop needed for
   this) to BEFORE `ensure_binary` in `chump-node-install.sh`'s main flow,
   not after `place_role_unit_files`/`reconcile_role_organs` at the end. The
   cap only has to exist in `~/.cargo/config.toml` before `cargo` runs once
   — it doesn't need the daemon alive yet.
3. **Serialize chump-build then almanac-build**, not just cap concurrency.
   Wrap both `build_binary_from_repo()`'s cargo invocation
   (`refresh-runner-binary.sh`) and `install-almanac.sh`'s cargo invocation
   in a shared `flock` on a repo-relative lockfile (e.g.
   `$STATE_DIR/.cargo-build.lock`), non-reentrant, so a retried run's
   synchronous chump build and a still-in-flight `disown`ed almanac build
   from an earlier run can never overlap — `flock -w <timeout>` gives a
   bounded wait instead of a silent race, and the timeout degrades to "build
   anyway, cap still applies" rather than deadlocking the install.
4. **`nice`+`ionice`** on both build invocations
   (`nice -n 10 ionice -c2 -n7 cargo build ...`) as the cheap immediate
   floor under the cap, so even before the lock is contended the two builds
   don't starve the organs that ARE already running (heartbeat, worker) on
   a 2-core box.

## Sequencing

**A before B.** B renders `--user` units from the SAME manifest A produces;
building B against the pre-union manifest would mean re-doing B's renderer
work once A adds `platforms=`/folds in the housekeeping roster. C's
"start node-orchestrator early" step needs B's rootless placement to exist
(there's no point starting the enforcer via a mechanism that still needs
root). C's "serialize builds" flock and nice/ionice steps do NOT depend on B
and could land independently — sequenced after B here only to keep the diff
in `chump-node-install.sh` reviewable (B and C both touch it, in disjoint
function ranges: B touches `svc_install`/`svc_up`/`svc_down`/
`place_role_unit_files`/`bootstrap_organ_deploy_via_sudo` around lines
110-190 and 943-1044; C touches `ensure_binary`/`build_binary_from_repo`/
`ensure_substrate`/`ensure_eyes`/main() around lines 720-810 and 1560-1580).
D and E are standalone one-file fixes with no dependency on A/B/C.

## Slices (filed, see INFRA-3867 for IDs)

- **A** — unified bill-of-materials: extend organ-manifest.txt schema,
  union bootstrap-manifest.yaml + install-node-housekeeping.sh's roster in,
  ship the mac-only-capability audit table above as a doc.
- **B** — rootless `--user` + linger placement: fix
  `place_role_unit_files()` and `svc_install()`/`svc_up()`/`svc_down()`/
  `svc_status()`, generalize `organ_unit_host_rewrite()`'s user-scope mode,
  reuse the `loginctl enable-linger` pattern from
  `install-fleet-health-sentinel.sh`.
- **C** — bring-up build staging: one-shot cap-enforcement before any
  build, `flock`-serialized chump-build → almanac-build, `nice`/`ionice`
  floor.
- **D** — fix `chump-mcp.json`'s hardcoded
  `/Users/jeffadkins/Projects/almanac/target/release/almanac-mcp` path so a
  fresh non-Jeff, non-macOS box doesn't get a dead almanac MCP entry.
- **E** — `chump-node-install.sh`'s `CHUMP_STORE_BACKEND` defaults new
  nodes to `postgrest` (line 461), a backend confirmed broken
  (`chump_anon` permission denied) — default to the canonical working
  backend instead of wiring every fresh node to a dead one.

## Slice A status (INFRA-7756, INFRA-7764..7771)

Slice A landed as 8 gaps: INFRA-7764 (platforms= field), INFRA-7765
(bootstrap-manifest.yaml fold-in), INFRA-7766 (install-node-housekeeping.sh
roster fold-in), INFRA-7767 (render-organ-roster.sh), INFRA-7768
(cross-consumer integration test — the four unified-BOM consumers agree on a
synthetic manifest), INFRA-7769 (regression test proving a REAL
pre-unification organ-manifest.txt still parses, cannot render a launchd
roster alone, and trips the documented INFRA-7766 fallback WARN), and
INFRA-7771. INFRA-7770 (this note) is that slice's fmt/clippy closure sweep:
`cargo fmt --all -- --check` and `cargo clippy --workspace --all-targets -- -D
warnings` were both green on main at the point every one of 7764-7769's
changes had landed — every file the slice touched (organ-manifest.txt,
bootstrap-manifest.yaml, the three shared libs, the two CI test scripts, the
fixtures) is bash/YAML/text, not Rust, so the slice introduced zero fmt/clippy
surface to begin with. Receipt: CI run
https://github.com/repairman29/chump/actions/runs/35517501643 (`fast-checks`
+ `clippy` both `success`) against main SHA
d187cae35e4e00d57d25f6cf131c3cb33d3f688b, the last commit before this note
that had 7764-7767 in and still ran green — re-confirmed after 7768/7769
landed since their added scripts/ci/*.sh and fixtures are likewise non-Rust.

## Non-goals

- Does not implement any of the slices (design + decompose only, per the
  task that produced this doc).
- Does not re-litigate rootless-vs-root (decided) or resolve the remaining
  macOS-only capabilities' Linux ports (that's real feature work, tracked as
  visible backlog by slice A, not solved by this doc).
- Does not touch the two known-filed gaps INFRA-3529 (fusion ranking favors
  code over docs) or INFRA-3530 (SQL unindexed) — orthogonal to placement.

## A note on existing sub-gaps INFRA-5817..5824

INFRA-3867 already carries 8 auto-decomposed sub-gaps (INFRA-5817 through
INFRA-5824) from an earlier pass. They describe copying unit files to
`/etc/systemd/system` and running `sudo systemctl enable --now` — i.e. the
root-requiring approach this doc (and the operator decision it implements)
explicitly rejects. They are **not** used as parents/siblings for slices
A-E below and should be treated as superseded once A-E are visible under
INFRA-3867; this doc does not close them (out of scope for a design-only
pass) but flags them so nobody picks one up and re-implements the wrong
shape.
