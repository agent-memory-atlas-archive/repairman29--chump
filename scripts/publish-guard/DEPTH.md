# publish-guard: depth chart

Green is not covered. Every line names its depth tier and what it leaves out. Update this file in
the same commit as the tests. All test terms are synthetic (`zorkmidbox`, `Initech Global`).

**Status: installed REPORT-ONLY (INFRA-7880).** Nothing here blocks a commit, a push, or a merge.

## What runs, and how deep

| Suite | Command | Depth | Count |
|---|---|---|---|
| Engine table test | `python3 scripts/publish-guard/test_publish_guard.py` | **edge**, plus a named adversarial set | 48 cases: smoke 2, happy-path 11, edge 12, adversarial 23 (3 of those are KNOWN-MISS pins) |
| Wrapper + hook wiring | `bash scripts/ci/test-publish-guard-report-only.sh` | **happy-path + edge** (sandbox repo, real hooks, fake HOME) | 23 assertions |
| Credential grep no longer echoes the value | `bash scripts/ci/test-credential-pattern-guard.sh` | **happy-path** | 2 assertions added |
| bot-merge call site | static grep inside the wrapper suite | **smoke** | 1 |
| CI workflow | static shape checks in the wrapper suite + `actionlint`; its live run is the check on the PR that added it | **smoke** | 3 |

The wrapper suite is chained from `test-credential-pattern-guard.sh`, so it runs in that test's CI
step and in its `chump preflight` mirror.

## What the wrapper suite pins

- A commit with a finding still succeeds. So does a commit when the engine cannot run (exit 2).
- No pattern file: falls back to `--builtin-only` and says so.
- A finding is reported as `file:line: class`; the matched value is never echoed.
- A term that appears only in the commit message is caught at the commit-msg stage.
- The ambient event carries class counts and no path, fingerprint or text.
- Registry paths (`.chump/state.sql`, `docs/gaps/`) are skipped in report-only mode.
- `--summary-only` (the CI mode) prints counts and no `path:line` pointers.
- The pre-commit call sits above the lean exit. The workflow has no `pull_request_target`.
- Neither the engine nor the wrapper reads an environment variable. There is no off switch.

## Gaps, named

Not written:
- A real `bot-merge.sh` run reaching the call (only a static check that the call exists).
- A commit from a linked worktree landing its event in the main checkout's ambient stream.
- Concurrent writers to the ambient stream. `python3` missing from PATH (the hooks skip silently).
- `range` mode has no assertion: it was exercised by hand and by the workflow's live run only.
- Engine: only 1 of 21 provider-key shapes has a positive case; `--git-range` on a multi-commit
  branch; line numbers across several hunks; quoted paths with octal escapes; CRLF, invalid
  UTF-8, a 1 MB single line (regex time); merge commits; the 200-line finding cap; a malformed
  overrides line; a pattern regex that does not compile; confusables outside the 40-entry table;
  regex denial of service from a crafted line.

Cannot be closed by any test here:
1. Images, PDFs, archives, compiled artifacts. A screenshot of a terminal is unreadable to this
   engine. `opaque-blob` refuses a short list of extensions by name; images pass with a count.
2. Encryption, compression, rot13, custom encodings, a term split across files or commits
   (three of these are pinned as KNOWN-MISS cases so nobody reports them as covered).
3. Paraphrase. Prose that reveals by description is a review problem, not a pattern problem.
4. Unknown unknowns. A denylist knows what the operator wrote down. The built-in shape rules
   (home path, private address, mailbox provider) are the only cover for terms nobody listed.
5. Everything that is not a diff, a commit message or a PR title and body: PR and issue
   comments, review comments, release notes, Actions logs of other workflows, branch and tag names.
6. Commits made with hooks skipped or absent. Report-only has no pre-push or CI-required layer.
7. An agent that edits the guard or its own pattern file. The threat model is a careless agent,
   not a hostile one. The CI job runs the PR's own copy of the engine, which is acceptable only
   because it counts and does not judge.
8. False-positive cost on a live fleet is unmeasured. Measuring it is what this phase is for.

## Before this goes blocking

Not in this change, and each needs the operator's decision: a pre-push call over the pushed
range, the `gh` wrapper, CI from the base branch with its own required context, an operator
signing key for the overrides file, and removing the registry-path skip.
