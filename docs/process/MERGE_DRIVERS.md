# Merge Drivers (INFRA-310 / INFRA-1389)

Chump uses custom git merge drivers so concurrent PRs that make independent
additive changes to the same file don't produce conflict markers.

## Why this matters

During active fleet sprints, 3-8 agents work simultaneously. Many file edits
are purely additive — each agent adds a new entry to a list-structured file.
Git's default 3-way merge sees two adjacent-line insertions as a conflict even
though they don't logically overlap. The drivers below resolve this
automatically, keeping PRs green without human intervention.

## Covered files (hot-file registry)

| File | Driver | Strategy |
|---|---|---|
| `.github/workflows/ci.yml` | `ci-yml-add-row` | Pure-append check + step-body validation |
| `docs/observability/EVENT_REGISTRY.yaml` | `union` (git built-in) | Unique-line union |
| `scripts/ci/env-vars-internal.txt` | `union` (git built-in) | Unique-line union |
| `web/v2/index.html` | `union` (git built-in) | Unique-line union |
| `scripts/git-hooks/pre-commit` | `pre-commit-add-guard` | Append guard blocks |
| `docs/gaps/*.yaml` | `gap-yaml-add-line` | Take ours (newest state) |
| `.chump/state.sql` | `chump-state-sql-regen` | Regenerate from canonical SQLite |
| `Cargo.toml` | `cargo-toml-append` (→ `merge-driver-append-only.sh`) | Pure-append + dedup |
| `web/v2/app.js` | `js-append` (→ `merge-driver-append-only.sh`) | Pure-append + dedup |
| `src/main.rs` | `rust-main-append` (→ `merge-driver-append-only.sh`) | Pure-append + dedup |

## The `union` driver (git built-in)

`union` ships with git core — no custom script, no entry in
`install-merge-drivers.sh`, no `%O %A %B %L` wiring. It's the right tool when
a file is a **flat, order-insensitive list** (one entry per line) that many
PRs append to concurrently: `git merge-file --union` concatenates both sides
and drops duplicate lines, so two branches that each add a distinct line
merge cleanly with zero conflict markers.

**When to reach for `union` instead of the custom append-only driver:**
`union` doesn't validate structure — it just concatenates and dedupes lines.
Use it for flat allowlist/registry files where every line stands alone (no
multi-line records, no ordering requirement). If a file has multi-line
records or ordering matters (e.g. `Cargo.toml` sections, `web/v2/app.js`
component blocks), use the custom `merge-driver-append-only.sh` instead (see
below) — it validates the pure-append precondition before merging, which
`union` does not.

### Installation

None required beyond the `.gitattributes` entry — `union` is a strategy name
git recognizes natively (`git help gitattributes`, search "union"). There is
no `git config merge.union.driver` step and no `install-merge-drivers.sh`
registration, unlike the custom drivers in this doc.

### Usage example

Add one line to `.gitattributes`:

```
scripts/ci/my-new-allowlist.txt merge=union
```

That's it. Verify with a synthetic conflict:

```bash
git checkout -b test-union-a main
echo "entry-a" >> scripts/ci/my-new-allowlist.txt
git commit -am "add entry-a"

git checkout -b test-union-b main
echo "entry-b" >> scripts/ci/my-new-allowlist.txt
git commit -am "add entry-b"

git checkout test-union-a
git merge test-union-b   # expect: clean merge, both entry-a and entry-b present, no conflict markers
```

### Files configured for `merge=union`

| File | Why it needs union | Gap ref |
|---|---|---|
| `docs/observability/EVENT_REGISTRY.yaml` | Many PRs each register one new ambient event kind; two additions on adjacent lines otherwise conflict textually with no semantic overlap. | INFRA-949 |
| `scripts/ci/env-vars-internal.txt` | Same append-one-line-per-PR pattern for tier-2/3 env var names. | INFRA-949 |
| `web/v2/index.html` | Append-only PWA hot file — each new feature adds a `<script src="X.js">` entry and/or a custom-element placement; concurrent feature PRs hit the same blocks. | INFRA-1201 |
| `scripts/ci/event-registry-reserved.txt` | Flat allowlist, one reserved-id per line, appended by many PRs concurrently. | RESILIENT-344 |
| `scripts/ci/ambient-emit-allowlist.txt` | Flat allowlist, one entry per line, same append pattern. | RESILIENT-344 |
| `scripts/ci/bypass-env-var-allowlist.txt` | Flat allowlist, one entry per line, same append pattern. | RESILIENT-344 |
| `scripts/ci/coord-shell-allowlist.txt` | Flat allowlist, one entry per line, same append pattern. | RESILIENT-344 |
| `scripts/ci/cross-pr-allowlist.txt` | Flat allowlist, one entry per line, same append pattern. | RESILIENT-344 |
| `scripts/ci/legacy-bypass-trailer-allowlist.txt` | Flat allowlist, one entry per line, same append pattern. | RESILIENT-344 |
| `scripts/ci/raw-gh-allowlist.txt` | Flat allowlist, one entry per line, same append pattern. | RESILIENT-344 |
| `scripts/ci/research-integrity-phantom-allowlist.txt` | Flat allowlist, one entry per line, same append pattern. | RESILIENT-344 |
| `scripts/ci/shell-test-allowlist.txt` | Flat allowlist, one entry per line, same append pattern. | RESILIENT-344 |
| `scripts/ops/organ-manifest.txt` | Append-only registry; textual conflicts here were reaping green, already-reviewed PRs on rebase. | INFRA-1688 |
| `scripts/setup/optional-installers-allowlist.txt` | Same append-only, reap-on-rebase pattern as `organ-manifest.txt`. | INFRA-1688 |
| `scripts/ci/preflight-ci-parity-exceptions.txt` | Same append-only, reap-on-rebase pattern as `organ-manifest.txt`. | INFRA-1688 |

This list is derived from `.gitattributes` — that file remains the source of
truth; re-grep it (`grep 'merge=union' .gitattributes`) if this table drifts.
The "why" column summarizes the rationale recorded in `.gitattributes`
comments at the time each entry was added.

## How the append-only driver works

`scripts/git/merge-driver-append-only.sh` handles all three INFRA-1389 files:

1. **Pure-append check**: verifies both branches start with the ancestor verbatim
   (no edits to the shared prefix). If either branch edited existing lines → exits 1
   (falls back to git's standard 3-way merge, which produces conflict markers).

2. **Tail extraction**: takes the lines theirs appended beyond the ancestor length.

3. **Deduplication**: filters out any theirs-tail lines already present in ours,
   preserving original append order. Prevents double-registration when two PRs
   independently add the same dependency (`serde = "1"`).

4. **Append**: writes the unique new lines to the end of ours.

**When it doesn't help (and shouldn't):** if two PRs both _edit_ the same line
(e.g., changing a dependency version), the driver correctly declines and lets
git mark the conflict for human resolution.

## What qualifies as append-only

A file is append-only with respect to a merge driver when:

- Each PR adds **new structural units** at the end (new dep line, new component
  class, new route arm, new event kind).
- No PR **removes or rewrites** existing entries in the shared section.
- The file has a clear structural delimiter that makes "new unit" detectable.

If a file stops being append-only (e.g., a PR that renames a dependency),
the driver exits 1 and git falls through to standard conflict resolution.

## Adding a new append-only file

1. Verify the file genuinely follows the append-only pattern.
2. Add a `.gitattributes` entry:
   ```
   path/to/file merge=my-driver-name
   ```
3. Add registration to `scripts/setup/install-merge-drivers.sh`:
   ```bash
   git config "merge.my-driver-name.name" "Description (INFRA-XXXX)"
   git config "merge.my-driver-name.driver" "scripts/git/merge-driver-append-only.sh %O %A %B %L"
   ```
4. Add a synthetic conflict simulation to `scripts/ci/test-merge-driver-coverage.sh`.
5. Document it in this file (the table above).

## Installation

Drivers are registered per-checkout in `.git/config` (not committed, per git
convention). They are auto-installed via:

```bash
bash scripts/setup/install-merge-drivers.sh
```

This is called automatically by `scripts/setup/install-hooks.sh` (which runs
on `post-checkout` and as part of `chump claim`). Manual verification:

```bash
git config --get-regexp '^merge\.' | grep -E 'driver|name'
```

## CI gate

`scripts/ci/test-merge-driver-coverage.sh` runs as part of the CI `test` job.
It asserts every hot file has a driver registered and simulates synthetic
append-only conflicts on each file to verify auto-resolution.
