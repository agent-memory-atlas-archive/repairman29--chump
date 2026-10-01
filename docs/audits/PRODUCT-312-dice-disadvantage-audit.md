---
doc_tag: audit
owner_gap: PRODUCT-312
status: fix-prepared-blocked-on-archive
---

# PRODUCT-312 — dice disadvantage logic bug + repo audit

## 1. Logic bug (AC #1)

Repo: `repairman29/dice` (private, Vite/React TTRPG dice roller — tip-jar candidate).

**Root cause** — `src/types/dice.ts::applyAdvantageDisadvantage`:

```ts
export const applyAdvantageDisadvantage = (results: DiceResult[]): DiceResult[] => {
  if (results.length !== 2) return results;
  const [first, second] = results;
  if (first.value > second.value) {
    return [first, { ...second, discarded: true }];
  } else {
    return [{ ...first, discarded: true }, second];
  }
};
```

This always keeps whichever of the two values is larger — it has no notion
of advantage vs. disadvantage. The caller (`diceService.ts::rollAdvanced`)
tried to compensate by pre-sorting the pair (descending for advantage,
ascending for disadvantage) before calling the function, but the function's
own `first.value > second.value` branch ignores that ordering and keeps the
max regardless. Net effect: **disadvantage silently behaved exactly like
advantage** (always took the better of the two rolls).

Verified against the original code with an isolated repro
(disadvantage path kept value `17` over `5` — i.e. the better roll):

```
disadvantage kept value (should be 5 if correct, bug if 17): 17
```

**Fix** — `applyAdvantageDisadvantage` now takes an explicit
`mode: 'advantage' | 'disadvantage'` and decides which roll to keep
directly, independent of input order:

```ts
export const applyAdvantageDisadvantage = (
  results: DiceResult[],
  mode: 'advantage' | 'disadvantage'
): DiceResult[] => {
  if (results.length !== 2) return results;
  const [first, second] = results;
  const keepFirst = mode === 'advantage'
    ? first.value >= second.value // advantage: keep the higher roll
    : first.value <= second.value; // disadvantage: keep the lower roll
  return keepFirst
    ? [first, { ...second, discarded: true }]
    : [{ ...first, discarded: true }, second];
};
```

`diceService.ts::rollAdvanced` now just passes `mode` through instead of
pre-sorting — removes the fragile sort-then-hope-the-callee-agrees pattern.

Added `src/types/dice.test.ts` (vitest) with 4 cases: advantage keeps the
higher roll, disadvantage keeps the lower roll, and both directions
verified with reversed input order (so the fix isn't accidentally
order-dependent again). Added `vitest` devDependency + `npm test` script
(repo had no test runner wired despite a `tests/` folder and a CI step
that ran `npm test --if-present`, which was a silent no-op).

All 4 tests pass against the fix; the first (`advantage keeps the higher
roll`) reproduces the bug and fails against the original code.

**Status: fix implemented and verified locally, committed to branch
`fix/disadvantage-roll-logic` (commit `6a2c8c2`) — NOT pushed.** Push is
blocked:

```
remote: This repository was archived so it is read-only.
fatal: unable to access 'https://github.com/repairman29/dice.git/': ... 403
```

`repairman29/dice` is **archived**. Unarchiving is an admin action on a
repo outside this chump checkout — left for the operator rather than done
unilaterally from this gap. The fix + tests are ready to push the moment
the repo is unarchived (patch preserved on the local branch above).

## 2. Repo audit (AC #2)

| Check | Finding |
|---|---|
| License | `LICENSE` is "All rights reserved" / proprietary ("Copyright (c) 2026 repairman29 ... Unauthorized copying, modification, distribution, or use is strictly prohibited"). Inconsistent with a public tip-jar deploy — needs an explicit license decision (keep proprietary + ToS, or relicense) before going public. |
| Secrets | None found. Grepped all `.ts`/`.tsx`/`.json`/`.html`/`.js`/`.sh` (excluding `package-lock.json`) for API keys, tokens, passwords, common provider key prefixes (`AIza`, `sk-`, `ghp_`) — zero hits. 5-commit history, no secret-looking blobs. |
| Deploy | `deploy.sh` runs `npm run build` + `npm run deploy` (→ `gh-pages -d dist`, pushes `dist/` to the `gh-pages` branch via local git credentials). `vite.config.ts` sets `base: '/dice/'` consistent with GitHub Pages project-site hosting. No secrets/tokens required in the script itself — relies on the operator's existing git push access. `deploy.sh`'s success-banner URL (`your-username.github.io/ttrpg-dice-roller`) is stale/placeholder text, not a functional issue. |
| CI | `.github/workflows/ci.yml` runs `npm install` + `npm test --if-present` on push/PR to `main`. Was a silent no-op (no test script existed); now exercises the new vitest suite once pushed. |
| Repo state | **Archived (read-only)** as of this audit — blocks any push, including this fix. Must be unarchived before dice can ship publicly or receive this fix. |

## Next steps (operator decision)

1. Unarchive `repairman29/dice`.
2. Push branch `fix/disadvantage-roll-logic` (commit `6a2c8c2`, prepared in
   this audit) as a PR, merge.
3. Decide the public license posture before the tip-jar launch (proprietary
   "all rights reserved" is fine for a hosted-but-not-OSS site; just
   shouldn't claim open-source anywhere in the pitch).
