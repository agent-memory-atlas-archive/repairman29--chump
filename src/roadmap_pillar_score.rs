//! META-409 (META-152 slice): roadmap-bottleneck-pillar alignment scoring.
//!
//! Parses `docs/ROADMAP.md` into "lanes" (each `## ...` section), counts how
//! often each of the 4 pillars (Effective / Credible / Resilient / Zero-Waste)
//! is mentioned in a lane, and scores each lane by how strongly it aligns
//! with the *currently most-starved* ("bottleneck") pillar(s) — the pillars
//! with the fewest open pickable gaps per `roadmap_status::PillarCoverage`.
//!
//! A lane that talks about a starved pillar a lot outranks a lane that talks
//! about a well-covered pillar a lot, even with the same raw mention count.

use crate::roadmap_status::PillarCoverage;
use std::collections::HashMap;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Pillar {
    Effective,
    Credible,
    Resilient,
    ZeroWaste,
}

impl Pillar {
    pub const ALL: [Pillar; 4] = [
        Pillar::Effective,
        Pillar::Credible,
        Pillar::Resilient,
        Pillar::ZeroWaste,
    ];

    pub fn as_str(&self) -> &'static str {
        match self {
            Pillar::Effective => "EFFECTIVE",
            Pillar::Credible => "CREDIBLE",
            Pillar::Resilient => "RESILIENT",
            Pillar::ZeroWaste => "ZERO-WASTE",
        }
    }

    /// Case-insensitive keyword(s) that count as a mention of this pillar
    /// inside a lane's ROADMAP.md text. Zero-Waste also matches the
    /// space-separated spelling used in prose (vs. the title-tag hyphenated
    /// form).
    fn keywords(&self) -> &'static [&'static str] {
        match self {
            Pillar::Effective => &["effective"],
            Pillar::Credible => &["credible"],
            Pillar::Resilient => &["resilient"],
            Pillar::ZeroWaste => &["zero-waste", "zero waste"],
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct Lane {
    pub title: String,
    pub mentions: HashMap<Pillar, usize>,
}

/// Splits `docs/ROADMAP.md` content into lanes on `## ` headings and counts
/// pillar-keyword mentions within each lane's body (heading line included).
pub fn parse_lanes(content: &str) -> Vec<Lane> {
    let mut lanes: Vec<Lane> = Vec::new();
    let mut current: Option<Lane> = None;

    for line in content.lines() {
        if let Some(title) = line.strip_prefix("## ") {
            if let Some(lane) = current.take() {
                lanes.push(lane);
            }
            current = Some(Lane {
                title: title.trim().to_string(),
                mentions: HashMap::new(),
            });
            continue;
        }

        if let Some(lane) = current.as_mut() {
            count_mentions(line, &mut lane.mentions);
        }
    }

    if let Some(lane) = current.take() {
        lanes.push(lane);
    }

    lanes
}

fn count_mentions(line: &str, mentions: &mut HashMap<Pillar, usize>) {
    let lower = line.to_lowercase();
    for pillar in Pillar::ALL {
        let hits = pillar
            .keywords()
            .iter()
            .map(|kw| lower.matches(kw).count())
            .sum::<usize>();
        if hits > 0 {
            *mentions.entry(pillar).or_insert(0) += hits;
        }
    }
}

/// Weight each pillar by how starved it is: fewer open (pickable) gaps for
/// that pillar → higher weight. Weight = 1.0 / (open_count + 1), so a pillar
/// with 0 open gaps (maximally starved / bottlenecked) weighs the most.
pub fn bottleneck_weights(coverage: &PillarCoverage) -> HashMap<Pillar, f64> {
    let mut weights = HashMap::new();
    weights.insert(Pillar::Effective, 1.0 / (coverage.effective as f64 + 1.0));
    weights.insert(Pillar::Credible, 1.0 / (coverage.credible as f64 + 1.0));
    weights.insert(Pillar::Resilient, 1.0 / (coverage.resilient as f64 + 1.0));
    weights.insert(Pillar::ZeroWaste, 1.0 / (coverage.zero_waste as f64 + 1.0));
    weights
}

#[derive(Debug, Clone)]
pub struct LaneScore {
    pub title: String,
    pub score: f64,
    pub mentions: HashMap<Pillar, usize>,
}

/// Scores each lane as sum(mentions[pillar] * bottleneck_weight[pillar]),
/// sorted descending by score (ties broken by title for determinism).
pub fn score_lanes(lanes: &[Lane], weights: &HashMap<Pillar, f64>) -> Vec<LaneScore> {
    let mut scored: Vec<LaneScore> = lanes
        .iter()
        .map(|lane| {
            let score = lane
                .mentions
                .iter()
                .map(|(pillar, count)| {
                    weights.get(pillar).copied().unwrap_or(0.0) * (*count as f64)
                })
                .sum();
            LaneScore {
                title: lane.title.clone(),
                score,
                mentions: lane.mentions.clone(),
            }
        })
        .collect();

    scored.sort_by(|a, b| {
        b.score
            .partial_cmp(&a.score)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.title.cmp(&b.title))
    });
    scored
}

/// Convenience: parse `docs/ROADMAP.md` under `repo_root` and score its lanes
/// against the current pillar coverage (INFRA-1145) from `state.db`.
pub fn build_report(repo_root: &std::path::Path) -> Vec<LaneScore> {
    let roadmap_path = repo_root.join("docs").join("ROADMAP.md");
    let content = std::fs::read_to_string(&roadmap_path).unwrap_or_default();
    let lanes = parse_lanes(&content);
    let report = crate::roadmap_status::build_report(repo_root);
    let weights = bottleneck_weights(&report.pillar_coverage);
    score_lanes(&lanes, &weights)
}

pub fn render_text(scores: &[LaneScore]) -> String {
    let mut out = String::new();
    out.push_str("═══ Roadmap Pillar-Bottleneck Alignment ═══\n\n");
    for (i, s) in scores.iter().enumerate() {
        out.push_str(&format!("{}. [{:.3}] {}\n", i + 1, s.score, s.title));
        let mut mention_strs: Vec<String> = s
            .mentions
            .iter()
            .map(|(p, c)| format!("{}={}", p.as_str(), c))
            .collect();
        mention_strs.sort();
        if !mention_strs.is_empty() {
            out.push_str(&format!("   {}\n", mention_strs.join(" ")));
        }
    }
    out
}

pub fn render_json(scores: &[LaneScore]) -> String {
    let entries: Vec<String> = scores
        .iter()
        .map(|s| {
            let mut mention_strs: Vec<String> = s
                .mentions
                .iter()
                .map(|(p, c)| format!("\"{}\":{}", p.as_str(), c))
                .collect();
            mention_strs.sort();
            format!(
                r#"{{"title":{},"score":{:.6},"mentions":{{{}}}}}"#,
                serde_json::to_string(&s.title).unwrap_or_else(|_| "\"\"".to_string()),
                s.score,
                mention_strs.join(",")
            )
        })
        .collect();
    format!("[{}]", entries.join(","))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_lanes_splits_on_headings() {
        let content = "\
## Lane A
This lane is about being Effective and Credible.

## Lane B
This lane focuses on Resilient work.
";
        let lanes = parse_lanes(content);
        assert_eq!(lanes.len(), 2);
        assert_eq!(lanes[0].title, "Lane A");
        assert_eq!(lanes[1].title, "Lane B");
    }

    #[test]
    fn count_mentions_is_case_insensitive_and_cumulative() {
        let content = "\
## Lane A
EFFECTIVE work here. More effective work. And Credible too.
";
        let lanes = parse_lanes(content);
        assert_eq!(lanes[0].mentions.get(&Pillar::Effective), Some(&2));
        assert_eq!(lanes[0].mentions.get(&Pillar::Credible), Some(&1));
        assert_eq!(lanes[0].mentions.get(&Pillar::Resilient), None);
    }

    #[test]
    fn zero_waste_matches_both_spellings() {
        let content = "\
## Lane A
Zero-Waste discipline and also zero waste practice.
";
        let lanes = parse_lanes(content);
        assert_eq!(lanes[0].mentions.get(&Pillar::ZeroWaste), Some(&2));
    }

    #[test]
    fn bottleneck_weights_favor_starved_pillar() {
        let coverage = PillarCoverage {
            effective: 0,
            credible: 10,
            resilient: 10,
            zero_waste: 10,
        };
        let weights = bottleneck_weights(&coverage);
        let effective_w = weights[&Pillar::Effective];
        let credible_w = weights[&Pillar::Credible];
        assert!(
            effective_w > credible_w,
            "starved pillar (0 open gaps) should weigh more than a well-covered one"
        );
    }

    #[test]
    fn lane_aligned_with_bottleneck_pillar_scores_higher() {
        let lanes = vec![
            Lane {
                title: "Bottleneck-aligned lane".to_string(),
                mentions: HashMap::from([(Pillar::Effective, 3)]),
            },
            Lane {
                title: "Well-covered-aligned lane".to_string(),
                mentions: HashMap::from([(Pillar::Credible, 3)]),
            },
        ];
        // Effective is starved (0 open gaps); Credible is well covered (10 open gaps).
        let coverage = PillarCoverage {
            effective: 0,
            credible: 10,
            resilient: 10,
            zero_waste: 10,
        };
        let weights = bottleneck_weights(&coverage);
        let scored = score_lanes(&lanes, &weights);

        assert_eq!(scored[0].title, "Bottleneck-aligned lane");
        assert!(scored[0].score > scored[1].score);
    }

    #[test]
    fn equal_mentions_equal_weight_ties_broken_by_title() {
        let lanes = vec![
            Lane {
                title: "Zeta".to_string(),
                mentions: HashMap::from([(Pillar::Effective, 1)]),
            },
            Lane {
                title: "Alpha".to_string(),
                mentions: HashMap::from([(Pillar::Effective, 1)]),
            },
        ];
        let coverage = PillarCoverage::default();
        let weights = bottleneck_weights(&coverage);
        let scored = score_lanes(&lanes, &weights);
        assert_eq!(scored[0].title, "Alpha");
        assert_eq!(scored[1].title, "Zeta");
    }
}
