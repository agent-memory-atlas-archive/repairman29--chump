# Echeo Ship Velocity Score — formula reference (INFRA-1816 slice)

Source: `repairman29/echeo` at commit `afbe64d6ddea1a89a486015eac1d9584b26d785f`,
`src/matchmaker.rs::calculate_ship_velocity_score` (lines 51-106). Full harvest
brief: [`docs/arsenal/cross-pollination/CP-005-echeo-ship-velocity-score.md`](./arsenal/cross-pollination/CP-005-echeo-ship-velocity-score.md).
Chump's port lives at `src/gap_scoring.rs::calculate_gap_value_score`.

## Exact expression (echeo original)

```
score = cosine_similarity(need_embedding, capability_embedding)

if language_of(capability) appears in need.description:
    score += 0.1                      # language boost

if kind_of(capability) (function|component|class) matches a same-shaped
   mention in need.description:
    score += 0.05                     # type/kind boost

score = min(score, 1.0)               # cap at 1.0
```

Sub-threshold gate (applied *before* scoring, in `match_need`): candidates
with `cosine_similarity <= 0.3` are dropped and never scored.

## Terms

| Term | Value | Fires when |
|---|---|---|
| Base | `cosine_similarity(need, capability)` — cosine of two 768-dim `nomic-embed-text` embeddings | always (this is the base score) |
| Language boost | `+0.1` | `need.description` (lowercased) contains `capability.language` (lowercased) |
| Type boost | `+0.05` | `capability.kind` and `need.description` agree on one of `function` / `component` / `class` |
| Cap | `min(score, 1.0)` | always applied last |

`reasons: Vec<String>` accrues in emission order (similarity -> language ->
kind -> existence) alongside the score, for audit-trail replayability.

## Chump port (`src/gap_scoring.rs`)

Chump's `calculate_gap_value_score` is a direct port with one substituted
term and one added term (see `gap_scoring.rs:8-18` for the full adaptation
notes):

- **Base** — Jaccard string-overlap of `gap.skills_required` vs.
  `worker_caps.skills` (v0), in place of embedding cosine similarity. Same
  `0.0..=1.0` shape and same threshold (`SIMILARITY_THRESHOLD = 0.3`).
- **Language boost** — `LANGUAGE_BOOST = 0.10`, identical to echeo.
- **Domain boost** — `DOMAIN_BOOST = 0.05`, echeo's kind/type boost
  reinterpreted as "gap.domain matches worker's last shipped class".
- **Recency term (new, not in echeo)** — `RECENCY_BOOST = 0.05`, added or
  subtracted based on the worker's last ship outcome for this gap's domain
  within a 24h window (`RECENCY_WINDOW_HOURS`).
- **Cap** — `score.clamp(0.0, 1.0)`, matching echeo's `min(1.0)` plus a floor
  at `0.0` (echeo has no floor since it has no term that can go negative).
