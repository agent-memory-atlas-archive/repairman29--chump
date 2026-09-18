# echeo Ship Velocity Score — formula reference

Source: `repairman29/echeo`, `src/matchmaker.rs::calculate_ship_velocity_score`
(lines 53-106), commit `afbe64d6ddea1a89a486015eac1d9584b26d785f` (CP-005).

Reproduced verbatim (see `docs/arsenal/cross-pollination/CP-005-echeo-ship-velocity-score.md`
for full context, mapping to Chump's gap-value scorer, and the v0/v1 rollout plan):

```rust
// echeo/src/matchmaker.rs:53-106 (verbatim)
// Original commit: afbe64d6ddea1a89a486015eac1d9584b26d785f
fn calculate_ship_velocity_score(
    similarity: f32,
    capability: &EmbeddedCapability,
    need: &Need,
) -> (f32, Vec<String>) {
    let mut score = similarity;                          // base: cosine of embeddings
    let mut reasons = Vec::new();

    if similarity > 0.7 {
        reasons.push(format!("High semantic similarity ({:.0}%)", similarity * 100.0));
    } else if similarity > 0.5 {
        reasons.push(format!("Moderate semantic similarity ({:.0}%)", similarity * 100.0));
    }

    // Language boost
    if need.description.to_lowercase()
        .contains(&capability.language.to_lowercase()) {
        score += 0.1;
        reasons.push(format!("Language match: {}", capability.language));
    }

    // Kind boost (function/component/class triplet)
    let need_lower = need.description.to_lowercase();
    let kind_lower = capability.kind.to_lowercase();
    if (kind_lower.contains("function") && need_lower.contains("function"))
        || (kind_lower.contains("component") && need_lower.contains("component"))
        || (kind_lower.contains("class") && need_lower.contains("class")) {
        score += 0.05;
        reasons.push(format!("Type match: {}", capability.kind));
    }

    score = score.min(1.0);                              // clamp
    (score, reasons)
}
```

## Formula summary

- **Base** = cosine similarity of two 768-dim embeddings (need description vs.
  capability code+name+kind blob).
- **+0.1** if the need description mentions the capability's language.
- **+0.05** if the need description and capability kind agree on
  function/component/class.
- **Clamp** to `1.0` (no lower clamp — inputs are non-negative by construction).
- Candidates with `similarity <= 0.3` are filtered out before scoring
  (`match_need`, line 122) and never reach this function.
