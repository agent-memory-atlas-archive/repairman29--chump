---
doc_tag: audit
owner_gap: PRODUCT-316
status: staged-pending-jeff-and-auditor
---

# PRODUCT-316 — holler giveaway staging (GIVEAWAY_SOP A-F)

## 1. Source

Jeff greenlit 2026-09-26 (content-architecture audit, workspace-docs PR #6):
spin holler out as a public OSS giveaway. GIVEAWAY_SOP.md Phase A-D work
already exists as `repairman29/holler#4` ("Giveaway prep (PREP ONLY)"),
opened 2026-09-26. This gap's job was to bring that PR current and verify
release-readiness, not to start from scratch — and not to flip anything
public (that stays Jeff + release-auditor gated, AC #3/#4).

## 2. State found vs. state left

`holler#4` had already been through one release-auditor NO-GO/fix cycle
(commit `27386f9`, 2026-09-26): the shipped library defaults pointed
anonymous public INSERT at Jeff's shared prod Supabase project
(`rbfzlqmkwhbvrrfdcain`, also Olive's over-quota project) — exactly the
class RELEASE_CHECKLIST.md section **2h** (added same week, via
PRODUCT-318) now names explicitly. That fix was already landed and verified
clean; this session's job was to re-verify it still holds and get the PR
back to mergeable against current `main`.

Work done this session:
1. **Rebased `giveaway/public-prep` onto `main`** — one real conflict
   (`.gitignore`, both branches added one; kept this branch's version, a
   strict superset of main's). PR is now `MERGEABLE`/`CLEAN`.
2. **Re-ran the secret sweep** (AC #2): full-tree + full-git-history grep
   for key-prefix patterns (`sk-`, `ghp_`, `AKIA`, `sb_secret_`, PEM
   headers, `||`-fallback literals) — zero hits beyond documentation
   placeholders (`sb_publishable_YOUR_KEY_HERE`).
3. **Re-verified default-target isolation** (RELEASE_CHECKLIST 2h): live
   HTTP probe against the old shared-DB project with the old key now
   returns `401 Invalid API key` — the key isn't just hidden, it's gone
   from the shipped code. `rbfzlqmkwhbvrrfdcain` does not appear anywhere
   in the tree.
4. **Re-ran tests**: 15/15 green.
5. **Updated the PR description** with the current readiness summary (was
   stale from before the NO-GO fix landed) and pushed.

No code behavior changed beyond the merge commit — the actual readiness
fix was already shipped by a prior session.

## 3. AC-by-AC

- **AC #1** (LICENSE + README + quickstart + bundle staged on a PR):
  satisfied by `holler#4`, now rebased and current.
- **AC #2** (release-readiness: no live secret; revoke-before-publish
  n/a): verified clean this session (see §2.2-2.3 above). Revoke-gate is
  N/A — there is no live key left in the shipped defaults to revoke.
- **AC #3** (release-auditor RELEASE_CHECKLIST GO before public flip):
  **not obtained — out of scope for this gap.** A formal auditor pass is a
  separate, dedicated review step; this session re-verified the items an
  auditor would check but does not substitute for that review.
- **AC #4** (public flip + launch post stay Jeff-gated): untouched —
  repo visibility was not changed, nothing was posted.

## 4. Outstanding Jeff asks (not resolved here, by design)

- **ASK-025** — Apache-2.0 vs. AGPLv3 (plus the separate "de-vendor into
  Olive" option). PR stages Apache-2.0 as the LICENSING.md-floor
  recommendation; swap before publish if Jeff picks AGPLv3.
- **ASK-058** — which tag the giveaway quickstart should reference.
  `package.json` has stayed at `0.2.0` across tags `v0.2.0`/`v0.2.1`/
  `v0.3.0` (version field never bumped past the first). Quickstart
  currently cites `v0.2.0`, which is internally consistent
  (matches `package.json`, tag exists) but may not be the tag Jeff wants
  as the public face of the giveaway.

## 5. Next steps (operator / release-auditor)

1. Jeff answers ASK-025 and ASK-058.
2. A release-auditor session runs the full RELEASE_CHECKLIST.md against
   `repairman29/holler#4` (sections 1-13) and returns a formal
   PASS/FAIL/N-A table + GO/NO-GO verdict.
3. On GO: merge `#4` to `main`, repo visibility flip and launch post stay
   captain (Jeff) actions per GIVEAWAY_SOP Phase E.
