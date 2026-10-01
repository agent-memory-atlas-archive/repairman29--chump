---
doc_tag: audit
owner_gap: PRODUCT-313
status: fix-shipped
---

# PRODUCT-313 — em-dash regression across 6 live sites

## 1. Source

Webcopy audit (cloud agent, 2026-09-26, workspace-docs PR #3) — byte-level
greps of raw live HTML found em dashes on 6 sites despite the 2026-07-18
rebrand recording prose-em-dashes-removed-sitewide. Each site is a separate
GitHub repo; fixed directly there (this session has admin push access) with
a doc-only record landing here, same pattern as PRODUCT-315.

## 2. Fixes shipped

| Site | Repo | PR | What changed |
|---|---|---|---|
| jeffadkins.dev | [jeffadkins-dev](https://github.com/repairman29/jeffadkins-dev) | [#9](https://github.com/repairman29/jeffadkins-dev/pull/9) merged | All 19 em dashes in `index.html` (9 decorative numbered headings, 9 label:desc bullets, 1 CSS comment) + `games/index.html` (4 decorative headings) + `rune-gatherer/index.html` / `starfall/index.html` (title tags, credits line). Decorative numbering `01 — Title` → `01. Title`; label bullets `<b>X</b> — desc` → `<b>X</b>: desc`; clause-joiners → comma/period by context. |
| shopolive.xyz | [olive](https://github.com/repairman29/olive) | [#84](https://github.com/repairman29/olive/pull/84) merged | Homepage (`src/app/page.tsx`), `/concept` demo mock, `help`/`privacy`/`terms`/`connect` pages, and `layout.tsx` site title. ~29 instances across error toasts, placeholders, and body copy — comma/period/colon by context. Pre-existing `build` CI failures on this PR (an `npm audit` CVE in `next`/`brace-expansion` and a flaky PKCE e2e test) predate this change and are unrelated — verified the new `check-no-em-dash` step passed cleanly. |
| peakvinyl.club | [pvc](https://github.com/repairman29/pvc) | [#3](https://github.com/repairman29/pvc/pull/3) merged | Bylaws (7 Article headings `Article I — Name` → `Article I: Name` + 2 legal-prose dashes), `supporting`/`contact`/`directory`/`membership` pages, site title (`layout.tsx`), event metadata. |
| d6consortium.com | — (no linked repo) | not fixed | **Logged, not fixed.** Per `workspace-docs/SITES.md` and `DOMAINS.md`, d6consortium.com is "unmapped — no d6consortium repo appears in PROJECTS.md," deployed via Vercel CLI from a local tree that isn't in any tracked git remote. No source to patch this session. Next step is an operator decision: either locate/recreate the source tree under version control, or accept the 1 counted em dash as a manual one-off fix next deploy. |
| postsub.io | [postsub](https://github.com/repairman29/postsub) | [#1](https://github.com/repairman29/postsub/pull/1) merged | 2 meta description em dashes (`public/index.html`) + 1 hero line (`public/studio-landing.html`). |
| echeo.ai | [echeo-platform](https://github.com/repairman29/echeo-platform) (was `echeo-web`) | [#4](https://github.com/repairman29/echeo-platform/pull/4) merged | 3 homepage copy em dashes (`app/page.tsx`), matching the audit's count exactly. |

All fixes are mechanical punctuation swaps (comma / period / colon / parens
depending on context) — no sentences were rewritten, per the gap's explicit
instruction not to rewrite in Jeff's voice.

## 3. CI gate shipped (AC #4)

Each repo above got a `scripts/check-no-em-dash.sh` (or
`website/scripts/check-no-em-dash.sh` for pvc) that fails if `—` (U+2014)
appears in the scoped public-facing files, wired into each repo's existing
CI (`ci.yml`) or a new minimal workflow (`jeffadkins-dev`, `pvc` had no CI
at all before this). Scope is deliberately narrower than "every tracked
file":

- **Excluded, same repos:** code comments (`//`, `/* */`, `{/* */}`) —
  stripped before the check runs, not rendered prose.
- **Excluded, by design:** `app/member/**` / `app/admin/**` (pvc),
  `src/app/shop/**` / `src/app/admin/**` and API JSON error strings
  (olive), `AnalyticsHub.tsx` (postsub) — these use `—` as a **missing-value
  table placeholder** (e.g. a date or dollar amount not yet set), a
  different, legitimate UI convention from the AI-tell prose em dash this
  gap targets. Flagged here rather than silently matched by the gate so a
  future reviewer knows it's a deliberate scope line, not an oversight.
- **Excluded:** `jeffadkins-dev`'s embedded game bundle JS
  (`realm/assets/`, `gravedancer/assets/`, `rune-gatherer/assets/`,
  `starfall/assets/`) — compiled output from 4 separate private game repos
  (`realm-of-shadows`, `grave-dancer`, `rune-gatherer`, `space-shooter`).
  Fixing those HUD/toast strings requires touching source + a rebuild in
  each of those repos; out of scope for this pass.

## 4. Next steps (operator decision)

1. **d6consortium.com** has no git-tracked source — decide whether to
   recreate it under version control (so this and future fixes are
   possible) or treat it as a manual one-off.
2. If the broader in-app/authenticated copy on shopolive.xyz (e.g.
   `src/app/shop/page.tsx`, API error strings) should also go through a
   full no-em-dash pass, file a follow-up gap — this pass stayed scoped to
   what the audit counted (public marketing/legal/meta pages) to match the
   gap's `m` effort sizing.
3. If the 4 arcade game repos' HUD/toast copy should be de-em-dashed too,
   file a follow-up gap against each (`realm-of-shadows`, `grave-dancer`,
   `rune-gatherer`, `space-shooter`) — that's source + rebuild work in
   different repos, not a doc-only fix.
