---
doc_tag: audit
owner_gap: PRODUCT-315
status: fix-shipped
---

# PRODUCT-315 — mytrove.app agency-polish register + unreceipted claims + stale 2024 copyright

## 1. Source

Browser DOM pass 2026-09-26 (in-app browser, rendered copy) covering the two
Firebase SPAs the curl-based webcopy audit couldn't reach: mytrove.app
(`repairman29/trove-web`) and sendpov.xyz.

## 2. mytrove.app — fix (AC #1 / #2 / #3)

Three issues found in `repairman29/trove-web`:

1. **Stale copyright year** — footer hardcoded `&copy; 2024 MyTrove` across
   8 pages (homepage, help, 6 blog posts). Switched to
   `{new Date().getFullYear()}` so it self-corrects going forward.
2. **Unreceipted social-proof claims** — "Join thousands of collectors who
   trust MyTrove", "Join Collectors Worldwide", "Join thousands of
   collectors organizing their treasures" — no backing number anywhere in
   the app. Replaced with copy that claims nothing unverified (e.g.
   "Organize your treasures, your way").
3. **Agency-polish register** — "ultimate platform for collectors",
   "AI-powered insights", "intelligent organization", "intelligent
   recognition", "powerful search" is generic SaaS voice, not Jeff's
   warm/curious/self-deprecating register. Per the gap's explicit
   instruction, this was **not** agent-rewritten — left in place with
   `TODO(Jeff, PRODUCT-315)` comments at both sites (hero subtitle,
   features section intro) marking the copy that needs his words.

Shipped as `repairman29/trove-web#11` (branch
`product-315-webcopy-polish`), merged directly — repo is active, this
session has admin push access, default branch is `master` not `main`.

## 3. sendpov.xyz — logged, not fixed (AC #4, low priority)

Clean and minimal; no em dashes. One mild register note: "No scripts. No
friction." (the anti-meeting tool's tagline) leans slightly punchy/hardboiled
— the other banned costume — but is otherwise fine and not worth a
standalone fix at P2/low-priority. No code change made; logging this per
the gap's AC #4 for whoever next touches sendpov.xyz copy.

## 4. Next steps (operator decision)

1. Jeff supplies replacement hero/feature copy for the two
   `TODO(Jeff, PRODUCT-315)` sites in `repairman29/trove-web`'s
   `src/app/page.tsx`.
2. If sendpov.xyz's punchy register bothers Jeff enough to fix, file a
   follow-up gap — not blocking, no AC violation as-is.
