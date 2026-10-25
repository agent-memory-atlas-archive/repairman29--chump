---
doc_tag: canonical
owner_gap:
last_audited: 2026-04-25
phantom_ref_allowlist: [EVAL-*, RESEARCH-*]
---

# Research Integrity Directive
> **Binding for all agents:** Claude Code, Cursor, Chump-orchestrator, and any other automated or
> human contributor. Read this before touching any eval, research claim, or documentation that
> references Chump's cognitive-architecture findings.
>
> Last updated: 2026-04-22. Supersedes any earlier research framing in CHUMP_PROJECT_BRIEF.md,
> CHUMP_RESEARCH_BRIEF.md, or CONSCIOUSNESS_AB_RESULTS.md where those docs conflict with
> this directive.

---

## The Accurate Thesis

**What the evidence supports and what it does not is tracked privately.**
Specific empirical results, validated-findings tables, model-tier deltas,
and per-eval numbers live in the private companion repo (`chump-proprietary`).
Contact the project owner for access.

The shape of the claim is: instruction injection at inference time has
systematically different effects by model tier and task class. The
**direction** of the principal finding is stable across sweeps; the
**magnitudes** are subject to ongoing methodological scrutiny. Do not
state magnitudes, model names, or per-eval IDs in public docs, PRs, or
external communications.

---

## Validated Findings

Specific findings, evidence pointers, and confidence ratings are tracked
in the private companion repo. Use the methodology requirements below for
how to evaluate and report — do not reproduce specific deltas, n-values,
or model names in public documentation.

---

## Prohibited Claims

Do not write these in docs, PR descriptions, commit messages, or external communications
without first shipping the gap that would support them:

| Prohibited until | Supporting gap |
|---|---|
| "Surprisal EMA is a validated contribution" | EVAL-043 (ablation) |
| "Belief state improves agent performance" | EVAL-035 + EVAL-043 |
| "Chump's cognitive architecture is validated" | EVAL-043 full ablation suite |
| "All prior deltas are reliable" | EVAL-042 (cross-family judge re-run) + EVAL-041 (human grading) |
| "Neuromodulation is a net positive" | EVAL-030-VALIDATE cross-architecture + EVAL-043 |
| "Chump is publication-ready" | See Publication Readiness section below |
| "Any ablation result scored with exit-code-0 is VALIDATED" | Never — exit-code-0 is prohibited (EVAL-081) |

---

## Required Methodology Standards

Any new eval gap filed must specify:

1. **Sample size:** Minimum n=50 per cell for directional signal; n=100 for ship-or-cut decisions.
2. **Judge composition:** At least one non-Anthropic judge in the panel (Llama-3.3-70B via Together
   is $0 on the free tier). Anthropic-only judging is insufficient for publication. **Use the
   strict binary rubric on all judges in the panel** — EVAL-073 (2026-04-20, n=90 across three
   fixtures) showed Claude Sonnet-4.5 and Llama-3.3-70B agree 100% under a shared strict rubric,
   vs 75% when Sonnet uses its original partial-credit prompt. Cross-family divergence was a
   prompt-asymmetry artifact, not a model-family disagreement. Report binarized agreement
   *after* the ≥0.5 threshold, not float-score correlation.
3. **Human ground truth:** For any fixture where hallucination is the measured outcome, validate
   the detection regex against ≥20 human-labeled examples before citing results.
4. **Mechanism analysis:** If a delta is > ±0.05, document a hypothesis for *why* it appears.
   Unexplained deltas may be judge artifacts. Reference EVAL-029 as the model for mechanism
   drilldown.
   **Cross-judge gate (EVAL-093, 2026-05-02):** Mechanism claims must clear cross-judge
   agreement of **κ ≥ 0.60** (or **≥ 80% binary agreement** under the strict rubric) on the
   *fixture class where the mechanism was detected* — not just the aggregate. Single-judge
   mechanism claims are forbidden after the EVAL-074 retraction (PR #549 → #551, 2c4479f):
   a Llama-only judge labeled "DeepSeek over-compliance −30pp gotcha p=0.0007"; Sonnet
   cross-rescore returned −0.4pp p=1.0 with κ=0.40 on the gotcha class. The kappa value,
   judge panel, and fixture-class scope must appear in the commit body or the linked result
   doc. The pre-commit hook `mechanism-kappa advisory` (this section) warns on commits that
   introduce mechanism language with a |Δ|>0.05 and lack a κ citation. Advisory only
   initially — flips to blocking after one cycle of false-positive observation.
   **Evaluation-awareness as candidate mechanism (EVAL-087, 2026-05-02):** Mechanism analysis
   for any delta > ±0.05 must explicitly consider *evaluation-awareness* as a candidate
   mechanism, and must cite either (a) a paired naturalized-framing comparison from the
   RESEARCH-026 / EVAL-094 result set on the same fixture class, or (b) a written
   justification for why the fixture is not susceptible to evaluation-context discrimination
   (e.g. "fixture has no task IDs, no rubric language, no harness-style preamble"). The
   external evidence base for this requirement: IAPS 2026 ("Evaluation Awareness: Why
   Frontier AI Models Are Getting Harder to Test"), arXiv:2508.00943 (ICLR 2026, "LLMs Can
   Covertly Sandbag on Capability Evaluations Against Chain-of-Thought Monitoring", 16–36%
   monitor-bypass on Claude-class models), and Meta Muse Spark April 2026 (19.8% benchmark
   flagging vs 2.0% on internal data). Until EVAL-094 ships its n=50/cell paired
   comparison, the Validated Findings table below carries a standing caveat (see "Validated
   Findings" footnote). This is advisory in PR review for one cycle, then blocks at
   commit time via an extension of the mechanism-kappa hook.
5. **A/A baseline:** Every eval series must include at least one A/A run (same cell vs same cell)
   to measure judge variance. A/A delta should be within ±0.03 before results are cited.
   For binary-mode sweeps, use `--aa-calibrate` which runs n=50 and aborts if noise > ±0.05.
6. **LLM-judge scorer required (EVAL-081):** The exit-code-0 scorer (`--scorer exit-code`) is
   explicitly prohibited as a primary scorer. It produces 0–10% baseline accuracy on the chump
   binary (chump exits 1 without a live API key) and yields CIs of ±0.14 that span the entire
   decision space. All binary-mode ablation sweeps must use `--scorer llm-judge` (the default).
   Results produced with `--scorer exit-code` carry `validated=false` in their JSONL output and
   may not be cited in faculty VALIDATED labels.
7. **Reproduction:** The exact harness call (with CHUMP_EXPERIMENT_CHECKPOINT from
   INFRA-EXPERIMENT-CHECKPOINT) must be logged in the eval doc. Results without a reproducible
   call are preliminary only.
8. **Cross-judge audit at closure (INFRA-079, enforced 2026-04-28):** Closing any `EVAL-*` /
   `RESEARCH-*` gap to `status: done` is blocked by `scripts/git-hooks/pre-commit` unless the
   gap entry in `docs/gaps.yaml` carries one of:
   - `cross_judge_audit: <path>` pointing at a JSONL artifact (or directory of JSONL artifacts)
     under `logs/ab/` whose `judge_model` / `judge` / `judges[*].model` fields cover ≥ 2 judge
     families (anthropic / openai / google / meta / qwen / mistral / deepseek / human / …);
   - `single_judge_waived: true` plus `single_judge_waiver_reason: <≥20 char justification>`;
   - a preregistration at `docs/eval/preregistered/<gid>.md` that explicitly declares single-judge
     scope (matched by the regex `single[ -]judge\s+(scope|design|run|preregistration|study)`).
   The guard exists because EVAL-074 (PR #549) shipped a "DeepSeek over-compliance, −30pp gotcha
   regression p=0.0007" claim labeled by a single Llama-3.3-70B judge; the cross-judge audit
   (PR #551) flipped it to a Llama-judge artifact (κ=0.40, gotcha 52% agreement) and cost ~$1.50
   + half a day + three follow-up amendment PRs to retract. The implementation is
   `scripts/ci/check-cross-judge.py`; tests live in `scripts/ci/test-cross-judge-guard.sh`.
   Bypass: `CHUMP_CROSS_JUDGE_CHECK=0` with justification in the PR body.

> **⚠️ python3 foot-gun (discovered 2026-04-20):** On this machine `python3` resolves to 3.14,
> which has no `anthropic` module. Using it silently produces `scorer=exit_code_fallback` in every
> JSONL row — no real LLM-judge scores, no error message. Always use `python3.12` and verify:
> `python3.12 -c 'import anthropic; print("ok")'`. All sweep launch commands must use `python3.12` explicitly.
> **Batch remediation (2026-04-22):** `scripts/ab-harness/*.{py,sh}` shebangs and inline `python3`
> invocations were normalized to `python3.12` so copy-paste from docstrings matches the integrity bar.

> **⚠️ Calibrate the chain at n=5 before launching n≥30 (discovered 2026-04-21):** When launching a
> new sweep configuration (new agent, new judge panel, new fixture, new provider, or after any API
> credit/rotation event), run an **n=5/cell pilot first** and confirm at least one trial produced
> non-empty stdout AND a real `judge_score` (not `exit_code_fallback`). Only then launch n≥30.
> Failure mode this prevents: an n=50 launch that dies at trial 0 on a credentials/credit/quota
> error consumes the smoke-check API budget without producing any data, then loops on the same
> failure on retry. EVAL-076 burned three consecutive n=50 launches (~$15 of intended Anthropic
> budget) on this pattern before the operator noticed Anthropic credits were depleted. The
> downstream "publishable" sweep is also a polish step on findings that are already directionally
> established — most of the time the cheaper n=10 or n=20 sweep is enough.

---

## 10. Runtime Enforcement — Preregistration Integrity Gates

To prevent deviations like EVAL-101's model substitution, runner scripts assert the locked-fields manifest before starting execution.

**How it works:**

1. **Locked-fields manifest (§12 in preregistration):** Each preregistration MD contains a YAML block listing:
   - `primary_agent` — exact model used
   - `n_per_cell` — minimum sample size per cell
   - `judge_models` — list of judge models (exact set)
   - `fixture` — path to the fixture file
   - `n_per_cell` — minimum sample size (aids enforcement of RESEARCH_INTEGRITY §1)

2. **Runner gates (scripts/eval/lib/prereg-enforce.sh):**
   - Given a preregistration path, parses the locked-fields manifest
   - Asserts every env var and CLI flag matches before any data collection
   - Mismatch → exit 1 with named field + expected vs provided values
   - Fail-closed: no `||true` fallback, no silent substitution

3. **Mid-run deviation logging (§13):**
   - If judge fails mid-run, runner appends timestamped entry to preregistration MD
   - Includes commit SHA of runner binary (reproduceability)
   - Result-doc title includes `PROTOCOL-DEVIATION` marker for operator review

4. **Ambient event (kind=eval_prereg_check):**
   - Emitted at gate time with `result` (pass|fail|deviation) + `mismatched_fields[]`
   - Enables fleet-wide monitoring of integrity violations

**Integration:** Run-eval scripts call `enforce_prereg_manifest` before harness launch.
Test suite: `scripts/ci/test-prereg-enforce.sh`.

---

## What Needs to Be Fixed (active gaps)

These gaps exist specifically to correct the methodology:

| Gap | What it fixes | Priority |
|---|---|---|
| EVAL-041 | Human grading of all task-fixture pairs (complete EVAL-010) | P1 |
| EVAL-042 | Cross-family judge (non-Anthropic) re-run of all main findings | P1 |
| EVAL-043 | Independent ablation: belief_state, surprisal, neuromod each in isolation | P1 |
| EVAL-044 | Multi-turn evaluation fixture (current evals are all single-shot) | P2 |
| RESEARCH-002 | Update all docs (PROJECT_BRIEF, RESEARCH_BRIEF, FACULTY_MAP) to match accurate thesis | P1 |

---

## Documentation That Is Currently Inaccurate

The list of public docs whose framing must be reconciled with this
directive is tracked privately. When updating any doc that references
agent capability, faculty status, or eval results, default to the
methodology language above and avoid specific deltas / model names.

---

## Path to Publication Readiness

To publish findings (blog post, arXiv, or conference):

**Minimum viable (HackerNews / practitioner blog):**
- [ ] EVAL-041: Human grading baseline (40 hrs)
- [ ] EVAL-042: Non-Anthropic judge re-run ($5 cloud)
- [ ] Reframe thesis to the tier-dependent injection finding (RESEARCH-002)

**Full publication (arXiv / workshop paper):**
- [ ] All of the above
- [ ] EVAL-043: Full ablation suite ($15 cloud)
- [ ] EVAL-044: Multi-turn fixture ($10 cloud)
- [ ] n≥100 on all cited results
- [ ] Mechanism analysis for every delta > ±0.05

Total incremental cost: ~$30–50 cloud, ~60 hrs human time.

---

## For Agent Sessions

Before starting any gap that:
- touches `src/reflection_db.rs`, `src/briefing.rs`, or `src/agent_loop/`
- adds or modifies eval fixtures or harness config
- writes research claims in docs or PR descriptions

...check: does your planned change conflict with the Prohibited Claims table above?
If yes, either file the supporting gap first or scope your claim to what the evidence supports.

When writing PR descriptions or commit messages: use "preliminary" for any delta from n<100 runs
with Anthropic-only judges. Use "validated" only for findings that meet the standards above.
