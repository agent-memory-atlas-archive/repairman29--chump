---
doc_tag: canonical
owner_gap: RESILIENT-316
parent: RESILIENT-310
anchor: docs/FACTORY_VISION.md
last_authored: 2026-08-13
source: founder's letter to the chairman (2026-08-13)
---

# ChumpOS First Boot — meet the dreamer, then go

> The founder's dream, distilled: **ChumpOS should meet its dreamer at first boot, learn
> who they are while it assembles itself, and then go — heal, build, update, research,
> and drive itself toward their dream, asking them only when it must.**

This scaffold owns the **opening scene** (the OOTB experience) and names the **operating
covenant** the running OS lives by. It is a child of the operational plan
([CHUMPOS_OPERATIONAL_PLAN.md](CHUMPOS_OPERATIONAL_PLAN.md)); the plan says *what the loop
must do*, this says *what the first five minutes feel like and what character the OS keeps
forever after*. Gaps implement it; ATC executes.

---

## Part I — The opening scene (steps 1–7, mostly UNBUILT)

The experience, act by act:

**Act 1 — Install.** Target is a fresh Linux box (helsinki-class; Ubuntu is fine). User
gets to a terminal and runs one thing (`curl … | sh`, a bot told to do it, one day a
voice command). The install starts; **Rust compiles for a few minutes.** That dead time
is a UX liability — we must not just sit there.

The "bot told to do it" path is zero-touch (INFRA-3629): no human ever opens an editor
to paste creds. A bot/orchestrator passes exactly ONE credential source and the install
materializes `~/.chump/providers.env` itself:

```bash
# Source A: inline env var (value never appears in ps/argv/logs — only the
# source used, and which required keys are present/missing, is logged)
CHUMP_BOOTSTRAP_CREDS="$(printf 'CLAUDE_CODE_OAUTH_TOKEN=%s\nGH_TOKEN=%s\n' "$OAUTH" "$GH")" \
  curl -fsSL https://raw.githubusercontent.com/repairman29/chump/main/scripts/setup/chump-node-install.sh \
  | bash -s -- --role brain

# Source B: a ready-made file (KEY=VALUE lines), copied/scp'd onto the box first
bash scripts/setup/chump-node-install.sh --role brain --creds-file /path/to/providers.env
```

Missing-but-required keys after materialization produce a single clear error listing
exactly what to supply — see `chump-node-install.sh --help` for the full contract. The
same `--creds-file` / `$CHUMP_BOOTSTRAP_CREDS` contract is honored by
`scripts/setup/provision-chumpd-host.sh` for the always-on substrate host path.

**Act 2 — The Concierge (during the compile).** A voice fills the wait:
> "Beep boop… Hi, I'm Chump. Who are you? …It's a pleasure to meet you. Let's gather some
> intel while the factory is being assembled for you."

It interviews — enough to know the *prime* experience, not 100% OOTB:
- **Who** are they, and **what** did they come to build/fix?
- Get them **logged into GitHub**.
- **Air-gapped / local-LLM-only?** or cloud allowed?
- Connect **Discord**.
- **Autonomy level** — and the honest north star: the prime, full-tuned experience is
  **Discord + full autonomy, the human asked only when needed**; autonomy can be
  **self-learned and granted along the way**, not demanded up front.
- **Keys, tools** — what's available, what's off-limits.

**Act 3 — Boot with a soul.** The interview is saved to a **profile (`.json`)** that
ChumpOS **consumes on boot**. The OS comes up already knowing its dreamer, their dream,
and the *prime target*. It then computes the **path**: where we are → where we're going →
the steps between. Step 7: it knows its dreamer and their dream, and **it goes to work.**

**Current state:** the developer FTUE (`brew → init → gen → orchestrate`) exists; the
*concierge interview → profile.json → boot-with-a-path* experience does **not**. Nearest
existing work: COTG vision go/no-go (INFRA-3481). The autonomy-preferences layer that
gates everything has **zero coverage** today.

**Concierge principles:** never block the compile on an answer (interview is async, skips
are fine); every answer either configures a real capability or is honestly deferred; the
profile is the single source the OS boots from, versioned and re-editable.

---

## Part II — The Operating Covenant (steps 8–13, the running character)

What the OS *is* once it's up. Each clause is measurable and mapped to its owning gap.
**Today (2026-08-13) proved these are exactly our weak points — receipts in-line.**

| # | Covenant clause | State | Owning gap |
|---|-----------------|-------|-----------|
| 8 | **Heals + builds itself; never strands work in a PR queue** | 🔴 the farmer stranded the whole fleet 6h today; jammed PRs rot | RESILIENT-313/314 (heal), RESILIENT-311 (never-strand + post-outage sweep) |
| 9 | **Keeps itself updated; workers on the latest version** | 🔴 two divergent worker binaries found today (`.cargo` vs `.local`) | MISSION-027 (deploy-to-fleet drift), folded into RESILIENT-313 |
| 10 | **Keeps Almanac fresh and uses it religiously** | 🟡 index stranded on the Mac, 174 commits stale | INFRA-3612 (almanac off Mac) + NEW: use-it-in-every-decision |
| 11 | **Invests in itself — uses research (Tavily, etc.)** | 🟡 no research loop wired into the work | NEW: research-in-the-loop |
| 12 | **Maxes the free inference the overlords offer** | 🟡 partial | EFFECTIVE-309 (OpenRouter free tier) + the free-tier routing |
| 13 | **Self-driving + fully autonomous, gated ONLY by the user's preferences; knows its own capabilities and limits; ready when given the chance** | 🔴 **ZERO coverage** — no preferences-gated autonomy layer exists | **NEW: RESILIENT-317 (autonomy-preferences spine)** |

---

## The done-bar (how we know the dream is real)

A stranger with a fresh Ubuntu box types **one command**, chats with Chump for the three
minutes it compiles, and walks away from the terminal. Without touching it again, the OS:
knows who they are and what they want; is working toward it at the autonomy they granted;
heals itself, keeps its workers current, keeps Almanac fresh and consults it; researches
what it doesn't know; maxes free inference; and messages them — on Discord — **only when
it genuinely needs a human.** When that runs, unattended, for a stranger, the dream is
real.

## Pass to ATC
Epic **RESILIENT-316** owns this scaffold (child of RESILIENT-310). Keystones: the
concierge/profile onboarding (Part I), and **RESILIENT-317** — the autonomy-preferences
spine (covenant 13, the zero-coverage hole that gates everything else). The covenant
clauses map to the gaps above; the board re-audits each clause's state each cycle.
