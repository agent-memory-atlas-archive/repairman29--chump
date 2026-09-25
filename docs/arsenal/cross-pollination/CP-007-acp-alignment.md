# CP-007: ACP (Agent Client Protocol) alignment audit

**Source repo:** [`agentclientprotocol/registry`](https://github.com/agentclientprotocol/registry) (upstream)
**Fork under audit:** [`repairman29/registry`](https://github.com/repairman29/registry)
**Parent gap:** INFRA-1822 (verdict recorded in `docs/arsenal/HARVEST_ROADMAP.md:134`)
**This slice:** INFRA-5876 — fork-status verification + spec-surface documentation

## 1. Fork status vs. upstream HEAD

Verified live via `gh api` (no local clone exists on this machine — `local_clone: null` in `GLOBAL_ARSENAL.json`):

```
$ gh api repos/repairman29/registry --jq '{fork, parent: .parent.full_name, archived, pushed_at}'
{"fork": true, "parent": "agentclientprotocol/registry", "archived": true, "pushed_at": "2026-05-16T01:46:54Z"}

$ gh api repos/agentclientprotocol/registry/compare/main...repairman29:registry:main --jq '{ahead_by, behind_by, status}'
{"ahead_by": 0, "behind_by": 1164, "status": "behind"}
```

| Field | Value |
|---|---|
| `repairman29/registry.main` vs. `agentclientprotocol/registry.main` | **0 ahead / 1164 behind** |
| Fork `archived` | `true` |
| Fork last push | 2026-05-16T01:46:54Z |
| Upstream last push | 2026-09-25T15:44:23Z (still active — hourly auto-update cron per upstream README) |

**Note on the gap's stated numbers:** INFRA-5876's acceptance criteria (and the
INFRA-1822 harvest notes) recorded **276 behind** as of the original scan
(~2026-05-23). The fork's `main` branch has been static since 2026-05-16
(it is `archived`, so it can no longer receive pushes), while upstream has
kept advancing on its hourly version-bump cron. The literal "0 ahead / 276
behind" snapshot is stale by construction — re-running the same compare today
yields **1164 behind**, and that number will keep growing every hour the fork
stays archived. Treat "behind count" as a live metric, not a fixed fact:
re-run the `gh api .../compare/...` call above before citing a number.

**Verdict is unchanged despite the drift:** the fork is a dead, read-only
snapshot (GitHub archives forks; you cannot push to `repairman29/registry`
main). It tracks zero local commits ahead of upstream — i.e. it was never
used to stage independent registry changes on `main`. Any actual outbound
contribution work happened on **branches**, not `main` (see §4).

## 2. Upstream repo shape (as of 2026-09-25)

Root contents relevant to the spec surface:

```
agent.schema.json       # per-agent entry schema (draft-07 JSON Schema)
registry.schema.json    # aggregated registry index schema
FORMAT.md               # registry format + preview-channel semantics
AUTHENTICATION.md       # auth method requirements (Agent Auth / Terminal Auth)
CONTRIBUTING.md         # registration flow + CI validation rules
quarantine.json         # agents temporarily excluded from the build (id -> reason)
<agent-id>/agent.json   # one directory per registered agent
<agent-id>/icon.svg      # 16x16 monochrome icon, currentColor only
```

~50 agent directories present (claude-acp, codex-acp, gemini, goose, cursor,
github-copilot, opencode, qwen-code, etc.) plus a `quarantine.json` holding
7 agents currently excluded from the built registry (auth failures, missing
deps, postinstall issues, timeouts).

## 3. Capability / agent schema (`agent.schema.json`)

Each registered agent is a JSON object validated against draft-07 JSON
Schema. Required top-level fields: `id`, `name`, `version`, `description`,
`distribution`; `license_url` is additionally required unless `id ==
"dimcode"` (schema encodes this as an `if/else` exemption).

| Field | Type | Notes |
|---|---|---|
| `id` | string, `^[a-z][a-z0-9-]*$` | must match the containing directory name |
| `name` | string | display name |
| `version` | string, `^\d+\.\d+\.\d+$` | stable-channel semver, no prerelease suffix allowed |
| `description` | string | non-empty |
| `repository` / `website` | string (URI) | optional |
| `authors` | string[] | optional |
| `license` | string | SPDX id or `"proprietary"` |
| `license_url` | string (URI) | required (see exemption above) |
| `icon` | string | set automatically by the build from `icon.svg`, not hand-authored |
| `distribution` | object, `minProperties: 1` | one or more of `binary` / `npx` / `uvx`, `additionalProperties: false` |
| `preview` | object | optional unstable-channel block (see §5) |

### Distribution types

| Type | Shape | Notes |
|---|---|---|
| `binary` | map of platform id → `{archive, cmd, args?, env?, sha256?}` | platforms: `darwin-aarch64`, `darwin-x86_64`, `linux-aarch64`, `linux-x86_64`, `windows-aarch64`, `windows-x86_64`. Archive formats: `.zip`, `.tar.gz`, `.tgz`, `.tar.bz2`, `.tbz2`, or raw binary — installer formats (`.dmg`/`.pkg`/`.deb`/`.rpm`/`.msi`/`.appimage`) are explicitly rejected. `sha256` is optional but recommended. |
| `npx` | `{package, args?, env?}` | npm package, resolved via `npx <package> [args]` |
| `uvx` | `{package, args?, env?}` | PyPI package, resolved via `uvx <package> [args]` |

Validation additionally enforces (per `CONTRIBUTING.md`, checked in CI, not
in the JSON Schema itself): version-string match between the top-level
`version` and each distribution's pinned package/URL version, no `latest`
tags anywhere, and HTTP-200 reachability for every distribution URL.

## 4. Registration flow

1. Fork the repo, create a directory named exactly `<id>/`.
2. Add `<id>/agent.json` (schema above) and `<id>/icon.svg` (16×16,
   monochrome, `fill`/`stroke` restricted to `currentColor` / `none` /
   `inherit` — hardcoded colors fail validation).
3. Open a PR. CI runs `build_registry.py` (schema + ID + version +
   distribution + URL-reachability + icon validation) and
   `verify_agents.py --auth-check` (see §6).
4. On merge, a build step assembles the aggregated `registry.json` /
   `registry-for-jetbrains.json` / `registry-for-jetbrains-preview.json`
   index files and stamps the `icon` field.
5. **Post-registration**, an hourly cron auto-bumps `version` (and the
   pinned distribution refs) by polling npm / PyPI / GitHub Releases for
   each registered agent and committing directly to `main`. Agents without
   a GitHub `repository` URL fall back to manual version-bump PRs.

**Chump-specific finding (not in the original gap's scope, but directly
relevant to the "should we align" question INFRA-1822 asks):** two prior
attempts exist to register Chump itself in the upstream registry:

- PR [`agentclientprotocol/registry#240`](https://github.com/agentclientprotocol/registry/pull/240)
  "Add Chump agent" — opened 2026-04-16, **closed** (not merged) 2026-05-23.
- PR [`agentclientprotocol/registry#308`](https://github.com/agentclientprotocol/registry/pull/308)
  "feat: add Chump to ACP Registry" — opened 2026-05-16, still **open**,
  `mergeable: UNKNOWN` (stale — needs a CI re-run/rebase against current
  upstream `main` before it can move).
- Two abandoned branches remain on the fork itself: `add-chump` and
  `add-chump-agent`, each carrying a `chump/agent.json` + `chump/icon.svg`
  pair (id `chump`, binary distributions for darwin/linux via GitHub
  Releases `v0.1.2` tarballs, MIT license). These predate both PRs and were
  likely their staging branches.

This means the "should Chump register in the upstream ACP registry"
question already has live, unmerged artifacts — any follow-up decision
should start from PR #308, not from scratch.

## 5. Versioning model

- **Stable channel:** `version` field, always plain `X.Y.Z` (a prerelease
  suffix here is a validation error).
- **Preview channel (optional):** an agent may add a `preview: {version,
  distribution}` block. `preview.version` matches `X.Y.Z-preview.N` (1-based
  counter) **or** a plain `X.Y.Z` release — the schema/format doc treats
  "preview" as "newest known version," not strictly "prerelease," so a
  preview block can legitimately hold a stable release that's ahead of the
  declared stable channel.
- **Highest-of-both-channels wins** for the JetBrains preview index
  (`registry-for-jetbrains-preview.json`): if stable overtakes the preview
  line, the stable value is served and the stale preview block self-heals
  on the next hourly build rather than failing.
- `preview` is **stripped** from the standard `registry.json` and
  `registry-for-jetbrains.json` outputs — it only surfaces (as an ordinary
  entry, values substituted wholesale) in the dedicated
  `registry-for-jetbrains-preview.json` index.
- Preview distributions are restricted to `npx`/`uvx` (no `binary` preview)
  and are **never** auth-checked, reachability-probed, or included in the
  nightly protocol matrix — preview is explicitly "unverified, best-effort."

## 6. Authentication model

Per `AUTHENTICATION.md`, an agent must support **at least one** of two
methods to be listed (the broader ACP spec defines more, e.g. Environment
Variable Auth, but the registry only currently accepts these two):

| Method | Flow |
|---|---|
| **Agent Auth** (default, `type: "agent"` or omitted) | Agent runs its own OAuth flow end-to-end: opens a local HTTP server for the callback, opens the user's browser to the provider's auth URL, exchanges the code for tokens, stores credentials itself. |
| **Terminal Auth** (`type: "terminal"`) | Client re-launches the agent binary with auth-specific `args`/`env` (e.g. `--setup`) that **replace** (not merge with) the normal invocation, presenting an interactive TUI login; once done, the client resumes normal ACP invocation. |

CI enforces this at registration and on every hourly rebuild via
`python3 .github/workflows/verify_agents.py --auth-check`, which performs a
live ACP `initialize` handshake against the agent and asserts the response's
`authMethods` includes at least one entry with `type: "agent"` or
`type: "terminal"`. Agents that fail this (or other CI checks) land in
`quarantine.json` (id → human-readable failure reason) and are excluded
from the built registry index until fixed — 7 agents were quarantined as of
this scan (postinstall-script failures, missing native deps, `initialize`
timeouts/crashes on specific point releases).

## 7. Bottom line for INFRA-1822's "sequencing trap" question

This slice only extends the existing verdict recorded in
`docs/arsenal/HARVEST_ROADMAP.md:134` — it does not overturn it. The registry
fork is a dead, archived read-only snapshot with no independent commits of
its own; the live, actionable ACP surface for Chump is the two upstream PRs
(#240 closed, #308 open-stale) already targeting `agentclientprotocol/registry`
directly. If/when the operator wants to revisit ACP registry listing, the
next slice is "rebase and revive PR #308," not "re-fork and re-author from
the `repairman29/registry` snapshot."
