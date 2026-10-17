<!--
Title format (INFRA-088): lead with the human-readable change, gap ID in parens.
  good: stale-branch reaper workflow + script (INFRA-087)
  bad:  INFRA-087: workflow
External contributor without a gap ID? Drop the parens — a maintainer will file one.
-->

## Summary

<!-- 1-3 sentences: what changed and why. The "why" matters more than the "what" — the diff already shows the what. -->

## Gap

<!-- e.g. INFRA-085. New work needs a reserved gap (`chump gap reserve --domain INFRA --title "..."`).
Pure-doc fixes / typos can use `n/a`. -->

Gap: 

## Test plan

<!-- How you verified this works. For agent PRs, this is what bot-merge.sh ran:
- [ ] `cargo fmt --all -- --check`
- [ ] `cargo clippy --workspace --all-targets -- -D warnings`
- [ ] `cargo test --workspace`

For UI / CLI / docs changes, also describe what you exercised manually. -->

## Checklist

- [ ] Title follows the convention above (change first, gap ID in parens)
- [ ] Gap row in `.chump/state.db` (mirrored to `docs/gaps.yaml` via `chump gap ship --update-yaml`) is correct, or this is a `n/a` doc fix
- [ ] If this closes an `EVAL-*` or `RESEARCH-*` gap: pre-registration committed at `docs/eval/preregistered/<GAP-ID>.md` (else `CHUMP_PREREG_CHECK=0` with justification)
- [ ] If this adds a `docs/*.md` file: deleted one, OR included a `Net-new-docs: <reason>` trailer ([INFRA-009](docs/audits/RED_LETTER.md))
- [ ] Touched `web/v2/**`? Checked [`docs/design/PWA_STYLE_GUIDE.md`](docs/design/PWA_STYLE_GUIDE.md) for token/breakpoint/composition rules (INFRA-1593)
- [ ] Targets `main`; will land via the merge queue (`bot-merge.sh --auto-merge` or `gh pr merge --auto --squash`)
- [ ] Must NOT auto-merge yet? Add the `no-auto-merge` label or a line `Auto-merge: hold` here; every fleet armer honors it (RESILIENT-1613)

## Notes for reviewers

<!-- Optional: risk areas, follow-up gaps you filed, screenshots, anything that would be missed by reading the diff alone. -->
