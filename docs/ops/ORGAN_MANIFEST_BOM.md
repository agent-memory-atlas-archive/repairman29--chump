# The unified organ-manifest BOM

INFRA-7768/INFRA-7771 companion doc. Design rationale and the full "what was
broken, why this shape" writeup lives in
[`docs/strategy/ONE_COMMAND_INSTALL.md`](../strategy/ONE_COMMAND_INSTALL.md)
section 1 (INFRA-7756, slice A) — this doc is the shorter, task-oriented
version: what the schema actually is today, how to generate a filtered view
of it, and how to add to it without breaking a consumer.

## Status

Slice A (INFRA-7756's bill-of-materials unification) landed
INFRA-7764–INFRA-7768: `scripts/ops/organ-manifest.txt` is the single
declared roster every supervisor renders from, extended with `platforms=`
and `housekeeping=` fields so it can absorb what used to be three unlinked
files. A separate, formal `bom-schema.yaml` (INFRA-7762) has **not** been
built yet — until it lands, `organ-manifest.txt`'s own header comment (the
block this doc summarizes) is the authoritative schema reference, and this
doc + that header are what a formal schema file would otherwise duplicate.
Don't link to a `bom-schema.yaml` that doesn't exist yet; link to the real
file below.

## The schema (as implemented today)

One directive per line in `scripts/ops/organ-manifest.txt`:

```
<state>  <unit>  [role=ROLE] [requires=SPEC,SPEC,...] [platforms=SUPERVISOR,...] [housekeeping=<script>|<cadence>|<args>]
```

Blank lines and lines starting with `#` are ignored. Full field-by-field
detail (including every `requires=` spec kind) is in the manifest's own
header comment — read it there, not copied here, so there is exactly one
place it can go stale:

| Field | Meaning | Default when omitted |
|---|---|---|
| `state` | `enabled` (must be running) or `paging_off` (must stay silent) | — (required) |
| `role=` | `brain\|muscle\|data\|janitor\|trust` — scopes `--role` bring-up | `brain` |
| `requires=` | Comma-separated preconditions (`bin:`, `env:`, `dep:`, `file:`) gating applicability | none |
| `platforms=` | Comma-separated `systemd\|launchd\|runit` — which supervisor(s) this organ applies to (INFRA-7764) | `systemd` |
| `housekeeping=` | `<script>|<cadence>|<args>` — marks this organ as one of `install-node-housekeeping.sh`'s supervised loop-services (INFRA-7766) | not a housekeeping organ |

## The three consumers (one manifest, one filter each)

All three read `scripts/ops/lib/organ-manifest-lib.sh`'s
`organ_manifest_parse()` — there is one parser, not three:

1. **`scripts/ops/organ-reconcile.sh`** — the self-heal loop. Filters
   `ENABLED` to lines whose `platforms=` includes the current host's
   detected platform (`organ_current_platform()`, override via
   `CHUMP_ORGAN_MANIFEST_PLATFORM`), then reconciles live systemd state to
   match.
2. **`scripts/ops/render-organ-roster.sh`** — a read-only CLI over the same
   parser + filter, for a human auditing the roster or a future slice-B
   launchd/runit renderer:
   ```
   scripts/ops/render-organ-roster.sh --platform systemd --role brain,data
   scripts/ops/render-organ-roster.sh --platform launchd
   ```
   Prints `<unit>  role=<role>  platforms=<platforms>  requires=<requires>`,
   one line per applicable organ. Exits non-zero only if the manifest itself
   is missing/unparseable — an empty roster (e.g. `--platform runit` today)
   is not an error.
3. **`scripts/setup/install-node-housekeeping.sh`** (via
   `scripts/ops/lib/node-housekeeping-roster-lib.sh`'s
   `housekeeping_organs_from_manifest()`) — derives the (name, script,
   cadence) triples it installs from `housekeeping=` tokens, plus a
   documented two-organ carve-out (`pr-lander`, `rot-reaper` — see
   INFRA-7772 for the unit-name collision that keeps them out of this file
   for now). **Deliberately fails open**: a missing manifest, or one with
   zero `housekeeping=` lines, prints a `WARN (INFRA-7766)` to stderr and
   falls back to a built-in 10-organ roster rather than silently installing
   nothing. This is the opposite failure mode from the parser/renderer above
   (which fail *closed* — non-zero exit) — both are deliberate, and
   `scripts/ci/test-organ-manifest-bom-integration.sh` (INFRA-7768) verifies
   both directions against the real manifest.

`scripts/setup/bootstrap-manifest.yaml` (macOS bring-up) folds in the same
way but at one remove: each `id:` entry that has a matching organ carries an
`organ: chump-<name>` pointer into `organ-manifest.txt` instead of an
independent installer description (INFRA-7765). See
[`docs/ops/ORGAN_ROSTER_AUDIT.md`](ORGAN_ROSTER_AUDIT.md) for the full
match/rename/confirmed-absent audit behind those pointers.

## Migrating an existing manifest line / adding a new organ

- **Adding a plain organ** (systemd-only, no housekeeping supervision): add
  an `enabled` line with `role=` and `requires=` as needed. `platforms=` can
  stay omitted — it defaults to `systemd`, the pre-INFRA-7764 behavior, so
  nothing about existing lines needs to change.
- **Adding a macOS-only capability** (the bootstrap-manifest.yaml case): add
  one `enabled ... platforms=launchd` line even when no Linux port exists
  yet — this makes the Linux gap visible in the one source of truth instead
  of only living in a second file. See
  `docs/ops/ORGAN_ROSTER_AUDIT.md`'s "confirmed-absent" rows for the
  established pattern.
- **Widening an existing organ to a second platform** (the
  `fleet-server-launchd` case): widen the existing line's `platforms=` in
  place — `platforms=systemd` becomes `platforms=systemd,launchd` — rather
  than adding a second, duplicate line for the same capability.
- **Adding a housekeeping organ**: add `housekeeping=<repo-relative-script>|<cadence-seconds>|<extra-args>`
  to the `enabled` line (cadence `0` means the script self-loops, like the
  orchestrator). `install-node-housekeeping.sh` picks it up on its next run
  with no code change on its side — that's the point of INFRA-7766's
  fold-in. Verify with:
  ```
  bash -c 'source scripts/ops/lib/node-housekeeping-roster-lib.sh; housekeeping_organs_from_manifest scripts/ops/organ-manifest.txt' | grep <name>
  ```
- **After any edit**, `scripts/ci/test-organ-manifest-bom-integration.sh`
  (INFRA-7768) is the fastest local sanity check — it exercises all three
  consumers against both a synthetic and the real manifest and will fail
  loudly if a new line diverges between them.

## What this slice (A) does NOT do

Per `docs/strategy/ONE_COMMAND_INSTALL.md`, slice A is data-only — "zero
behavior change." It does not place units at `--user` scope, does not add a
launchd/runit renderer beyond the platform-filtered text output above, and
does not resolve the `pr-lander`/`rot-reaper` unit-name collision
(INFRA-7772). Those are slice B (INFRA-7757, rootless placement) and later.
