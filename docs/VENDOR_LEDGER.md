---
doc_tag: canonical
owner_gap: CREDIBLE-206
last_audited: 2026-08-10
---

# Vendor Ledger — dependency and quota truth doc

> **What this is.** The bucket-GO half of READY-GATE: one row per external
> dependency per lighthouse surface (arcade/games, upshift CLI+platform,
> olive), naming service, tier, quota, key owner, cost curve, and **verified**
> at-limit behavior. Sibling of `~/Projects/SITES.md` / `~/Projects/DOMAINS.md`
> (those cover domains and hosting; this covers service tiers, quotas, and
> degradation). Standing agent for the sweep: **infra-cartographer**.
>
> **No secret values here.** Key *names* and *owners* only — never paste a
> token, connection string, or secret value into this file. If you're about
> to paste something that starts with `sk-`, `eyJ`, or looks like a JWT/UUID
> credential, stop and write the key *name* instead.
>
> **Same-session doc-update rule (per CLAUDE.md).** Any change to a surface's
> live dependencies (new provider, tier upgrade, quota change) lands its
> ledger row update in the *same* PR as the change, not a follow-up.

## How to read a row

| Column | Meaning |
|---|---|
| Service | External dependency name |
| Tier | free / trial / paid, as billed today |
| Quota | The hard number(s) that trigger degraded/blocked behavior |
| Key owner / location | Who owns the credential and where it's referenced (name only, never value) |
| Cost @ 10 / 100 / 1000 users | Rough cost curve if usage scaled to that concurrent-user count |
| At-limit behavior | **VERIFIED** (receipt + date) or **ASSUMED — needs verification** (never leave a free/trial dependency here without a plan to verify it) |

---

## Surface 1 — arcade / games

**Shape.** A portfolio of browser games sharing one Supabase backend for
feedback + leaderboards (`games:shared/feedback-widget.js:25`,
`games:shared/leaderboard.js:21`). No per-game isolation — **every game in
the portfolio shares one tier's quota.**

| Service | Tier | Quota | Key owner / location | Cost @10 / @100 / @1000 users | At-limit behavior |
|---|---|---|---|---|---|
| Supabase (shared-mega-DB) | free (assumed — needs confirmation) | Supabase free tier: 500MB DB, 2GB egress/mo, 50k MAU (2026 published limits) | operator; referenced via env in `games:shared/feedback-widget.js`, `games:shared/leaderboard.js` | negligible @10; likely still free @100; **@1000 risks the shared egress/DB cap for the whole portfolio, not just the popular game** | **ASSUMED — needs verification.** No probe has been run against this project's actual plan/usage dashboard. Supabase's documented free-tier behavior at cap is read-only pause / write rejection, not deletion — but this has not been confirmed against *this* project via Supabase MCP `get_project`. |
| beast-mode.dev auth redirect target | dead | n/a — hostname is dead | Supabase project `fsmibduqvwnfyvypuaie` (hostname only, not a secret) | n/a | **VERIFIED DEAD, 2026-08-04.** Browser pass on beast-mode.dev found both primary CTAs 307-redirect to `fsmibduqvwnfyvypuaie.supabase.co`, which does not resolve/serve — an invited stranger hits a corpse today. This is the single highest-priority fix on this surface: either restore the project or repoint the CTA. |

**Shared-mega-DB blast radius (AC 5).** All games in the portfolio point at
the *same* Supabase project for feedback + leaderboard writes. One game going
viral (a Hacker News/Product Hunt spike, or a bot-scraper hitting leaderboard
writes) consumes egress/DB-size quota shared by every other game in the
arcade — a brownout on the popular title **browns out the whole portfolio's
backend**, including titles with zero traffic that day. There is currently no
per-game quota isolation, rate limit, or circuit breaker between games. This
is the concrete cost of the "one shared backend" architecture choice and
should be weighed before the arcade's next viral-traffic bet.

**Standing detector (c).** beast-mode.dev's dead-hostname class needs a
nightly posse/stranger-gate probe against each surface's auth + primary
endpoints — this is EFFECTIVE-368's "Stranger-GO line in RELEASE_CHECKLIST"
row (`docs/strategy/STRANGER_GATE_AND_FLEET_RADIO_2026-08-06.md`), status
**WIRE** as of 2026-08-06, not yet built. Until it ships, this ledger's
"at-limit behavior" column for beast-mode.dev-fronted surfaces must be
re-verified by hand each time a surface changes.

**Honest degradation shipped (EFFECTIVE-1643, EFFECTIVE-370 slice).** A
vendorable reference implementation for `games:shared/leaderboard.js` and
`games:shared/feedback-widget.js` lives at
[`patterns/arcade-honest-degradation/`](../patterns/arcade-honest-degradation/)
in this repo, CI-verified by
[`scripts/ci/test-arcade-honest-degradation.sh`](../scripts/ci/test-arcade-honest-degradation.sh)
against a simulated down/quota-exhausted (500/429/connection-refused)
backend: the leaderboard degrades to a "scores are napping" banner, the
feedback widget degrades to a non-blocking notice, neither path throws or
surfaces a raw 5xx, and the primary game loop is never gated on either
resolving successfully. Vendoring this into the live `games` repo (replacing
the current `shared/leaderboard.js` / `shared/feedback-widget.js`) is the
remaining step to close the at-limit-behavior gap on the Supabase row above.

**BEAST_MODE_API / BEAST_MODE_API_URL / BEAST_MODE_URL flag-drift triage
(PRODUCT-190, 2026-09-01).** The almanac flagmap drift report (2026-08-05)
flagged three env-var names for the same endpoint across 356 reads in
`repairman29/BEAST-MODE`, including a `beastmode.dev` vs `beast-mode.dev`
typo-domain. Verified against the live `repairman29/BEAST-MODE` clone
(`~/.chump/external/repairman29/BEAST-MODE/clone`) and DNS:
- `beast-mode.dev` (hyphenated) **resolves and serves (HTTP 200)** — this is
  the live, correct domain.
- `beastmode.dev` (no hyphen) **does not resolve** — confirmed dead, despite
  appearing as the "official" domain in `package.json` (`author`,
  `homepage`), the GitHub App manifest, and several mock/test emails.
- Every `BEAST_MODE_API` / `BEAST_MODE_API_URL` / `BEAST_MODE_URL` **default
  fallback** (`process.env.X || '...'`) checked (all ~40 sites with an inline
  default) already points at the live `beast-mode.dev` — the flag-name drift
  is real (3 names, no canonical alias layer) but is not currently routing
  live traffic to the dead domain.
- One confirmed live bug: `website/lib/services/experimentDeployment.ts`
  builds preview-deployment URLs as `` `https://${slug}.preview.beastmode.dev` ``
  — the dead domain. `foo.preview.beastmode.dev` does not resolve, so every
  generated preview link is broken today.
- Fix (consolidate the 3 flag names into one canonical `BEAST_MODE_API_URL`
  with the other two reading through it as aliases, and repoint
  `experimentDeployment.ts`) is genuine work in `repairman29/BEAST-MODE`
  (139 files touch these flag names), not in this repo — filed as
  **PRODUCT-202** with `skills_required: external_repo:repairman29/BEAST-MODE`
  so it routes through the external-repo execution path
  (`docs/design/EXTERNAL_REPO_EXECUTION.md`) once claimable, rather than
  being hand-edited outside this worktree. (The PRODUCT-201 slot referenced
  in the commit that added this section never actually persisted a gap —
  PRODUCT-190's ship re-verified the finding and re-filed it as PRODUCT-202.)

---

## Surface 2 — upshift (CLI + platform)

**Shape.** CLI tool (`upshift-cli`, published to npm) + an AI-assisted
platform layer. AI usage is metered *in code* — the pricing-tier/credit logic
exists (`upshift:skills/upshiftai/index.js` — `loadPricingTierCredits`,
`trackAIUsage`) — but per the operator the underlying provider buckets
themselves are still free/trial, not a paid production tier.

| Service | Tier | Quota | Key owner / location | Cost @10 / @100 / @1000 users | At-limit behavior |
|---|---|---|---|---|---|
| AI provider (backing `upshiftai`) | free/trial (operator-stated, 2026-08) | Not enumerated in-repo — `loadPricingTierCredits` reads a tier config, not a hard quota constant | operator; referenced via `upshift:skills/upshiftai/index.js` | @10 negligible; @100 likely still inside trial; **@1000 almost certainly exceeds a trial bucket** | **ASSUMED — needs verification.** `trackAIUsage` exists in code (usage IS metered), but no probe has confirmed what happens when `loadPricingTierCredits` returns zero remaining — reject the call? silently degrade? This needs a direct code read of the credit-exhaustion branch plus a live check of the actual provider account tier (not visible from this repo alone). |
| npm distribution (`upshift-cli`) | free (npm public registry — no quota-relevant tier) | n/a | n/a | n/a | n/a — not a quota-bearing dependency, but flagged because of the incident below |

**Receipt — the incident this ledger exists to prevent.** `upshift-cli` 0.5.5
sat **dead on npm for 14 days** — 726 downloads of a tarball missing `dist/`
— because no stranger ever ran it cold and no dependency/quota check caught
the broken publish
(`docs/strategy/STRANGER_GATE_AND_FLEET_RADIO_2026-08-06.md`). This is not a
quota failure, but it is exactly the class of "readiness is a feeling, not a
verified fact" this ledger is meant to close — the same discipline (verify,
don't assume) applies to publish integrity as to quota headroom.

---

## Surface 3 — olive

**Shape.** Kroger grocery-list app. Stacks three external dependencies:
Kroger OAuth, an AI layer, and Supabase.

| Service | Tier | Quota | Key owner / location | Cost @10 / @100 / @1000 users | At-limit behavior |
|---|---|---|---|---|---|
| Kroger OAuth / API | unknown — needs confirmation | Kroger developer-portal tiers are rate-limited per published API docs, exact number not yet pulled for this app's registered client | operator; olive's OAuth client config (name/location not yet catalogued in this pass) | not modeled — no receipt yet | **ASSUMED — needs verification.** Not probed this pass. Needs a read of olive's OAuth client registration + Kroger developer-portal dashboard for the actual rate-limit tier. |
| AI layer (agent orchestrator) | unknown — needs confirmation | `olive:src/lib/agent/orchestrator.ts` implements the VOICE_ADDENDUM contract (ported into `docs/ALMANAC.md`'s voice contract) but this pass did not re-derive its quota/tier | operator | not modeled — no receipt yet | **ASSUMED — needs verification.** |
| Supabase | unknown — needs confirmation | not yet probed for this project | operator | not modeled — no receipt yet | **ASSUMED — needs verification.** Likely a *separate* Supabase project from the arcade's shared-mega-DB (needs `list_projects` confirmation) — if so, olive does NOT share the arcade's blast radius; if it turns out to be the same project, the blast-radius note in Surface 1 applies here too. |

**Gap in this pass.** Olive's three dependencies could not be verified via
Supabase MCP `list_projects`/`get_project` or Vercel MCP in this session
(tool access unavailable in this worktree). This is the largest open hole in
the ledger — the next infra-cartographer sweep should prioritize olive
Surface 3 completion before any olive-facing publish decision.

---

## What's VERIFIED vs ASSUMED right now (honest summary)

| Surface | Rows | Verified | Assumed — needs verification |
|---|---|---|---|
| arcade/games | 2 | 1 (beast-mode.dev dead hostname) | 1 (Supabase free-tier at-limit behavior) |
| upshift | 2 | 0 | 1 (AI-provider credit-exhaustion behavior); 1 row is not quota-bearing (n/a) |
| olive | 3 | 0 | 3 |

**Total: 1 of 6 quota-bearing rows carry a VERIFIED at-limit receipt.** The
rest are flagged, not silently assumed — that is the honest state of AC 2
today. Closing the remaining 5 requires either live Supabase/Vercel MCP
access (unavailable in this pass's environment) or a manual dashboard check
by whoever holds the credentials. This ledger's job is to make that gap
*visible*, not to fabricate a verification that didn't happen.

## Next sweep checklist (for infra-cartographer)

1. Supabase MCP `list_projects` — confirm whether arcade and olive share a
   project (blast-radius question in Surface 3) and pull the actual plan tier
   for both.
2. Supabase MCP `get_project` on the arcade's project — confirm the free-tier
   assumption in Surface 1 against the real dashboard numbers.
3. Vercel MCP `list_projects` / `deployments` — none of the three surfaces'
   hosting tier/quota is captured yet; this pass covered backend dependencies
   only.
4. Kroger developer-portal — pull olive's actual registered rate-limit tier.
5. `upshiftai` credit-exhaustion branch — read the code path
   `trackAIUsage` takes when `loadPricingTierCredits` returns zero, and
   confirm the live provider account tier.
6. Wire the standing stranger/posse probe (EFFECTIVE-368) so beast-mode.dev-class
   dead-hostname rot is caught within 24h instead of discovered by a stranger.
