# Session syntheses

This directory holds session synthesis documents — post-session write-ups that capture what was built, what was learned, what surprised us, and where to pick up.

They are different from the ROADMAP (which tracks future plans) and from commit messages (which track individual changes). A synthesis is the narrative layer — what this cluster of work *meant*, told in a way another human or agent can read cold and actually orient from.

## What a synthesis covers

A good synthesis answers five questions:

1. **What shipped?** — concrete list of PRs, features, scripts, docs
2. **What was learned?** — methodology lessons, surprising results, calibration updates
3. **What failed?** — failure modes, wasted effort, operational footguns that got built around
4. **What did it cost?** — cloud spend, wall time, token budget
5. **Where to pick up?** — ordered, actionable, with no assumed context

If you cannot answer all five, the synthesis isn't done.

## Reading order

| Date | What happened |
|------|--------------|
| [2026-10-16](phase-r-ship-path-measurement-2026-10-16.md) | Phase R ship-path measurement of record — five ship-path gaps (INFRA-8204/8207/8202/8201/8198) landed through the fleet on cuphead, nineteen failure classes with receipts, proof run CREDIBLE-301 → PR #5500 merged with zero manual steps |
| [2026-04-18](../SESSION_2026-04-18_SYNTHESIS.md) | 36-hour autonomous loop — cognitive A/B science landed publishable result (+0.14 hallucination effect, 10.7× A/A noise floor), 9 crates extracted, 5 operational guards shipped, 24 PRs |

## How new syntheses get created

Currently: manually, by a Claude session agent or the human operator, using [TEMPLATE.md](TEMPLATE.md) as the starting format.

Automation: `scripts/eval/generate-sprint-synthesis.sh` (PRODUCT-005, shipped PR #124) reads git log + SQLite task completions + AB study results and generates a draft, then commits it here. Triggered as the `sprint_synthesis` round type in `heartbeat-self-improve.sh`.

## Frequency

One synthesis per major session cluster — roughly every 5-10 PRs of related work, or whenever the project crosses a meaningful milestone (first publishable result, architecture shift, new collaborator joining).

Not every heartbeat round needs one. The synthesis captures a *phase*, not a turn.
