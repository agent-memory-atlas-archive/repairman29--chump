---
doc_tag: audit
owner_gap: PRODUCT-318
status: fix-shipped
---

# PRODUCT-318 — default-target-isolation check added to RELEASE_CHECKLIST

## 1. Where the checklist actually lives

`RELEASE_CHECKLIST.md` (the release-auditor's "full dig") is not in the
`chump` repo — it's in `repairman29/workspace-docs`, local checkout
`/tmp/wsdocs`, alongside `.claude/agents/release-auditor.md` which reads it
fresh on every dig. (A stale `docs/RELEASE_CHECKLIST.md` did once exist in
`chump` but was a cargo-dist binary-release doc, removed in #85 as part of
the 127-stale-files cleanup — unrelated content, not this checklist.)

## 2. Fix (AC #1, #2)

Added item **2h** under section 2 (MOAT/SENSITIVITY, the blocking section
that already holds attack-surface (2d) and claims-match-reality (5b)):

> **2h. Default-target isolation** — the shipped DEFAULT config (DB
> connection string, API base URL, webhook/endpoint target) resolves to a
> placeholder or a dedicated throwaway, never a shared production
> resource. ... Failure modes this catches: **prod spam surface**,
> **blast radius**, and **load amplification on shared/quota-limited
> infra**. PASS = every default resolves to a placeholder/throwaway; FAIL
> = any default points at a DB/endpoint also used by another live project.

Cites the precedent verbatim from this gap's description: holler PR #4
(2026-09-26) shipping its default at the shared mega-DB
`rbfzlqmkwhbvrrfdcain` (also Olives prod, over quota) — public anonymous
INSERT into prod + amplified load on an at-risk org, only caught because
it doubled as an attack-surface (2d) + doc-mismatch (5b) finding.

Shipped as `repairman29/workspace-docs#8`
(branch `product-318-release-checklist-default-target-isolation`),
merged.

## 3. AC #3 — release-auditor references the new item id in future digs

No separate edit needed: `.claude/agents/release-auditor.md` step 1 is
"Read RELEASE_CHECKLIST.md fresh (it evolves — every incident adds an
item)" — the auditor re-reads the live checklist on every dig, so 2h is
picked up automatically starting with the next invocation. Confirmed by
reading the agent doc; it names no item IDs itself, it just walks the
checklist as-is.

## 4. Scope note

Per the auditor's own doctrine ("do not edit the checklist yourself unless
asked; that's a captain-reviewed change") — this gap *is* the captain-asked
edit (PRODUCT-318 description: "Auditor recommended but did NOT self-edit
the checklist (captain-reviewed doctrine change)"), so editing directly
here is in-scope, not a bypass of that doctrine.
