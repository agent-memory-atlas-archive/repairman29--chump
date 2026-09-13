# COTG — the "installed node" experience

**Goal (Jeff, 2026-08-17):** make "installed" a real, reproducible experience, not the
hand-assembly helsinki (and the current Pixel) grew into. One command turns an OWNED box
into a clean, self-supervising, self-testing ChumpOS node — host-agnostic (Termux / systemd
Linux / macOS). This is what RESILIENT-318 actually is.

## Why this exists
The 2026-08-17 helsinki teardown proved helsinki was ~half *installed* (reproducible from
`install-helsinki-atc.sh`) and ~half *built* — 11 load-bearing organs (worker@, keep-mergeable,
discord-gateway, electrician, …) were hand-placed with no installer, so a rebuild couldn't
reproduce them. The Pixel is the same disease one layer down: a RESILIENT-336 node accumulated
across `~/chump` (binary + junk), `~/chump-repo`, `~/chump-brain`, a boot supervisor, an
organs runner, and a now-dead-helsinki witness — none of it reproducible, half of it obsolete.
"Installed" must mean: **fresh box + one command + green self-test → a node that runs.**

## The one command
```
chump-node-install.sh --role brain|muscle|all [--home DIR] [--self-test-only]
                      [--control-plane-only] [--with-fleet-server]
```

## Phases (each idempotent, logged, verified)
1. **DETECT** — host kind (termux / linux-systemd / macos), arch, supervisor (runit `sv` /
   systemd / launchd), canonical paths. (Extends `node-describe.sh` to be Termux-aware.)
2. **HOME** — ONE canonical layout under `$NODE_DIR` (default `~/.chumpnode`): `repo/` (clean
   checkout), `bin/chump`, `organs/`, `logs/`. State stays at the established `~/.chump/`
   (providers.env, state.db, AUTONOMY_LEVEL, heartbeat). No junk-drawer, no multi-checkout.
3. **CREDS** — provider credentials enable worker execution, but they are not a
   prerequisite for installation. Without them—or with `--control-plane-only`—the
   node is a successful control plane: binary refresh, state, health, and (when
   requested) the cockpit remain available while the worker is deliberately stopped.
4. **BINARY** — a working `chump` binary at `$NODE_DIR/bin/chump` that passes a WARM smoke
   (answers a prompt). Termux builds on-device or via `deploy-pixel-node.sh` cross-compile.
4b. **SEED** (INFRA-3633) — one-shot `chump gap sync --pull` loading the canonical
   `$CHUMP_STATE_DB` (pinned at `$NODE_DIR`'s `$STATE_DIR/state.db`, never a repo-local
   `.chump/state.db`) from the git-tracked `docs/gaps/*.yaml` backlog, so a fresh box boots
   with the real gap queue instead of an empty store. Idempotent — respects the INFRA-3606
   terminal-status guard on re-run; no-op with a warning if no binary is installed yet or the
   store is unreachable.
5. **ORGANS** — install the role's organ set under the host supervisor, from a manifest.
   *brain*: heartbeat, node-describe-register, discord-gateway, coordination.
   *muscle*: worker, build/CI. Reproducible — the organ list is data, not hand-`cp`.
6. **SUPERVISE** — survive reboot: termux-boot hook (Termux) / systemd enable (Linux). Linux
   installs the binary-refresh timer targeting the same `$NODE_DIR/bin/chump` the worker uses.
   `--with-fleet-server` additionally installs the dashboard at
   `$NODE_DIR/bin/chump-fleet-server`; it binds localhost by default. Tailnet exposure is an
   explicit `CHUMP_FLEET_SERVER_BIND=<tailscale-ip>` operator choice.
7. **SELF-TEST** — the canary that defines "installed": host detected, binary answers,
   canonical store has a non-empty, docs/gaps-matching pickable gap count (INFRA-3633), every
   applicable role organ's supervisor entry is UP, and heartbeat is fresh. GREEN reports either
   `mode=work-ready` (provider worker enabled) or `mode=control-plane` (worker intentionally
   stopped); neither state is misreported as the other.

## Role → node (settled architecture)
- **Pixel = brain** (always-on, owned, in-pocket): coordination, registry, heartbeat,
  Discord (operator channel), witness. Credential home (providers.env, incl. Hetzner).
- **CJ = muscle**: worker, Rust builds, CI. Ships work; brain coordinates.
- CI compiles Rust, so the brain never needs to out-build anything.

## Non-negotiable: reproducible, not bespoke
Every organ is installed from the manifest by the installer. If an organ runs, an installer
created it — no hand-placed unit/service ever again. That is the one lesson from the helsinki
teardown, encoded.

## Standing proof: the cold-install FTUE harness (RESILIENT-1050)
The install *phases* are unit-tested (`scripts/ci/test-node-install-*.sh`,
`test-node-refresh-*.sh`, `test-resilient-1016/1036-*.sh`) and the cold install was proven
ONCE, in a burst, on the box **mugman** (RESILIENT-1016/1035/1036/1037). But mugman then
became a live node-2, so there was no *standing* "fresh box → full bring-up → assert clean
convergence → tear down" loop — a regression in the zero-to-working path could land unseen.

`scripts/ci/ftue-cold-install.sh` is that recurring proof. It **composes** the real bring-up
scripts (it never re-implements them) and reuses the existing assertions.

**What "a WORKING muscle node" means (the convergence bar the harness asserts):**
1. **worker unit ACTIVE** and wired to the tracked loop — `chump-worker` is active and its
   `$ORGAN_DIR/worker.sh` execs `scripts/dispatch/worker.sh` (the RESILIENT-1016 fix: the unit
   used to install but never go active because worker.sh was never materialized).
2. **fleet-server serves /healthz** — `curl http://127.0.0.1:7070/healthz` returns `ok`.
3. **refresh timer installed + enabled** — `chump-node-refresh.timer` (RESILIENT-200).
4. **binary PULLed, not cold-built** — `bin/chump.provenance` `source=release|ci-artifact`
   (never `build`) and NO `logs/binary-build-*.log` exists (the mugman cold-build timeout class).
5. **ZERO out-of-role / cruft units** — `organ-reconcile.sh --check` role-scoped to muscle
   exits 0 (no active/enabled unit outside the muscle manifest — the 28-cruft-unit class).

**Fidelity ladder (three layers, one assertion contract):**

| Layer | Command | Where it runs | Fidelity |
|---|---|---|---|
| Contract + live /healthz | `ftue-cold-install.sh --selfcheck` | any host (macOS/Linux/CI), no container | validates the bring-up CONTRACT statically + brings a real `chump-fleet-server` up, curls `/healthz`, tears it down |
| Clean container | `ftue-cold-install.sh --engine docker` | Linux host with Docker (CI `ubuntu-22.04`) | boots a clean Ubuntu 22.04 **systemd** container, runs the REAL bring-up, asserts all 5, tears down |
| Real disposable box | `ftue-cold-install.sh --engine docker` on the box, or the manual run below | a genuinely fresh Oracle A1 / mugman | true bare-metal |

`--engine docker` NEUTRAL-SKIPS to `--selfcheck` when a systemd container cannot be
provisioned (no daemon, cgroup/privilege limits, or a non-Linux host) — an environment that
cannot host the test is not a regression in the thing under test; a container that DOES come
up but fails to converge is a HARD failure.

**CI wiring:** `.github/workflows/ftue-cold-install.yml` (path-gated to the bring-up files, so
it never bloats a docs/Rust-only PR; weekly on a schedule) runs TWO steps on `ubuntu-22.04`:
- **gate** — `--selfcheck` (host-agnostic contract + real `/healthz`), the step that decides
  the job. Deterministic, doesn't depend on systemd-in-docker, so it is the hard, always-green
  gate.
- **advisory fidelity** — `--engine docker` (clean Ubuntu 22.04 systemd container, real
  end-to-end bring-up), `continue-on-error` so it is visible + continuous but never blocks the
  merge. systemd-in-docker IS functional on the `ubuntu-22.04` runner (verified 2026-09-07);
  full container convergence is being hardened under **RESILIENT-1051**, after which this step
  can be promoted to gating.

### Real-disposable-box variant (periodic bare-metal fidelity)
The container layer is the continuous single-shot proof; a genuinely fresh cloud box is the
periodic bare-metal proof (the free-Oracle-A1 rig precedent — see the "Fresh-box FTUE proof"
memory: a $0 Oracle A1 box proved chump-node-install ≠ ATC node and filed INFRA-3680..3685).
**mugman remains the historical real-box proving ground for this.** Run on a cadence
(monthly, or before any bring-up-path release), NOT on `cuphead`/`mugman` while they are live
nodes — spin a throwaway box:

```bash
# 1. Provision a FRESH free box (Oracle A1 via OCI when quota frees, or any fresh Ubuntu 22.04).
#    Cloud Shell OCI CLI provisions the A1 with zero local install (per the fresh-box memory).
# 2. SSH in as a non-root sudo user, then bring it up from ZERO exactly as the installer does:
export CHUMP_BOOTSTRAP_CREDS="$(printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\nGH_TOKEN=%s\n' "$OAUTH" "$GH")"
curl -fsSL https://raw.githubusercontent.com/repairman29/chump/main/scripts/setup/chump-node-install.sh \
  | bash -s -- --role muscle
git clone https://github.com/repairman29/chump.git ~/chump-host
bash ~/chump-host/scripts/setup/install-node-refresh-systemd.sh
bash ~/chump-host/scripts/setup/install-fleet-server-node.sh
# 3. Assert the SAME convergence bar the harness uses (5 checks above), e.g.:
systemctl is-active chump-worker
curl -sf http://127.0.0.1:7070/healthz            # -> ok
systemctl --user is-enabled chump-node-refresh.timer
grep '^source=' ~/.chumpnode/bin/chump.provenance # -> release|ci-artifact, never build
CHUMP_ORGAN_RECONCILE_ROLE=muscle bash ~/chump-host/scripts/ops/organ-reconcile.sh --check
# 4. DESTROY the box (it is disposable — never keep a proving-ground box as a node).
```

The bar is identical to the container harness's; the only difference is the substrate is a
real kernel + real cloud networking rather than a container, which is why it is the periodic
(not per-PR) fidelity check.
