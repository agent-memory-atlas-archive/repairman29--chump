//! INFRA-606: roadmap-status — reads docs/ROADMAP.md, shows progress against weekly outcomes.
//! INFRA-1145: adds starved_outcomes, untraced_p0, pillar_coverage, --exit-on-drift, --top-starved.
//!
//! `chump roadmap-status [--json]` parses docs/ROADMAP.md for Week N outcomes + gap refs,
//! cross-references against the gap registry (state.db), and emits a 🟢/🟡/🔴 progress table.

use std::path::Path;

#[derive(Debug, Default, Clone)]
pub struct RoadmapGap {
    pub id: String,
    pub is_placeholder: bool,
    pub status: String, // "shipped" | "in_flight" | "open" | "not_filed"
    pub closed_pr: Option<i64>,
}

#[derive(Debug, Default, Clone)]
pub struct WeekOutcome {
    pub week: u32,
    pub week_title: String,
    pub outcome: String,
    pub gaps: Vec<RoadmapGap>,
}

/// INFRA-1145 / CREDIBLE-238: per-pillar count of open (pickable) gaps,
/// including R&D so balance_restock can detect R&D starvation even though R&D
/// is excluded from the Gate-2 mission-ship ratio numerator.
#[derive(Debug, Default, Clone)]
pub struct PillarCoverage {
    pub effective: usize,
    pub credible: usize,
    pub resilient: usize,
    pub zero_waste: usize,
    pub rnd: usize,
}

/// META-1045: one outcome-table drift finding (see [`analyze_outcome_drift`]).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OutcomeDrift {
    pub outcome_id: String,
    pub title: String,
    /// `no_open_gaps` — a live outcome with a stated DoD and zero open gaps;
    /// `all_unpickable` — it has open gaps, but every one is blocked.
    pub kind: &'static str,
    pub detail: String,
    pub open_children: usize,
}

#[derive(Debug, Default, Clone)]
pub struct RoadmapStatusReport {
    pub weeks: Vec<WeekOutcome>,
    pub ts: String,
    /// INFRA-1145: week numbers where zero gaps are shipped or in-flight.
    pub starved_outcomes: Vec<u32>,
    /// INFRA-1145: open P0/P1 gap IDs not referenced in any ROADMAP week.
    pub untraced_p0: Vec<String>,
    /// INFRA-1145: per-pillar open gap counts.
    pub pillar_coverage: PillarCoverage,
    /// META-1045: outcome-TABLE drift — live outcomes with a stated definition of
    /// done but no open gaps, or whose open gaps are all unpickable.
    pub outcome_drift: Vec<OutcomeDrift>,
}

/// Dependency ids named by a gap's `depends_on` (a JSON array of ids, or a
/// comma/whitespace separated list).
fn dep_ids(depends_on: &str) -> Vec<String> {
    let t = depends_on.trim();
    if t.is_empty() {
        return Vec::new();
    }
    if let Ok(v) = serde_json::from_str::<Vec<String>>(t) {
        return v.into_iter().filter(|x| !x.trim().is_empty()).collect();
    }
    t.split(|c: char| c == ',' || c.is_whitespace())
        .map(|x| {
            x.trim()
                .trim_matches(|c| c == '[' || c == ']' || c == '"' || c == '\'')
        })
        .filter(|x| !x.is_empty())
        .map(String::from)
        .collect()
}

/// META-1045: an OPEN gap is unpickable when any dependency is not yet done.
/// (Only `open` is a pickable status — see GapStore::ship / the fleet picker.)
fn unpickable_reason(
    gap: &crate::gap_store::GapRow,
    done_ids: &std::collections::HashSet<String>,
) -> Option<String> {
    let unmet: Vec<String> = dep_ids(&gap.depends_on)
        .into_iter()
        .filter(|d| !done_ids.contains(d))
        .collect();
    if unmet.is_empty() {
        None
    } else {
        Some(format!("{} blocked by {}", gap.id, unmet.join(",")))
    }
}

/// META-1045: extend the roadmap-status drift analysis to the OUTCOME TABLE.
/// For every outcome that is still live (`status == "open"`, i.e. not done or
/// parked) AND states a definition of done:
///   * no open gap links to it                      -> `no_open_gaps`
///   * it has open gaps but all are unpickable      -> `all_unpickable`
///
/// Reproduces the 2026-08-07 case where the product lighthouse outcomes held
/// 0 / 0 / 1 gaps: two empty outcomes and one whose only gap was blocked.
pub fn analyze_outcome_drift(
    outcomes: &[crate::gap_store::OutcomeRow],
    open_gaps: &[crate::gap_store::GapRow],
    done_ids: &std::collections::HashSet<String>,
) -> Vec<OutcomeDrift> {
    let mut out = Vec::new();
    for o in outcomes {
        if o.status != "open" || o.definition_of_done.trim().is_empty() {
            continue;
        }
        let children: Vec<&crate::gap_store::GapRow> = open_gaps
            .iter()
            .filter(|g| g.outcome_id.as_deref() == Some(o.id.as_str()))
            .collect();
        if children.is_empty() {
            out.push(OutcomeDrift {
                outcome_id: o.id.clone(),
                title: o.title.clone(),
                kind: "no_open_gaps",
                detail: "has a stated definition of done but zero open gaps".to_string(),
                open_children: 0,
            });
            continue;
        }
        let reasons: Vec<String> = children
            .iter()
            .filter_map(|g| unpickable_reason(g, done_ids))
            .collect();
        if reasons.len() == children.len() {
            out.push(OutcomeDrift {
                outcome_id: o.id.clone(),
                title: o.title.clone(),
                kind: "all_unpickable",
                detail: format!(
                    "all {} open gap(s) unpickable: {}",
                    children.len(),
                    reasons.join("; ")
                ),
                open_children: children.len(),
            });
        }
    }
    out
}

pub fn parse_roadmap(content: &str) -> Vec<WeekOutcome> {
    let mut weeks: Vec<WeekOutcome> = Vec::new();
    let mut current_week: Option<WeekOutcome> = None;
    let mut in_implementing = false;

    for line in content.lines() {
        if let Some(rest) = line.strip_prefix("## Week ") {
            if let Some(w) = current_week.take() {
                weeks.push(w);
            }
            let parts: Vec<&str> = rest.splitn(2, " \u{2014} ").collect();
            let week_num: u32 = parts[0].trim().parse().unwrap_or(0);
            let week_title = parts.get(1).copied().unwrap_or("").to_string();
            current_week = Some(WeekOutcome {
                week: week_num,
                week_title,
                ..Default::default()
            });
            in_implementing = false;
            continue;
        }

        let w = match current_week.as_mut() {
            Some(w) => w,
            None => continue,
        };

        if line.contains("**Outcome.**") {
            w.outcome = line.replace("**Outcome.**", "").trim().to_string();
            continue;
        }

        if line.contains("**Implementing gaps") {
            in_implementing = true;
            continue;
        }

        if line.starts_with("**Out of scope") || line.starts_with("**Acceptance") {
            in_implementing = false;
            continue;
        }

        if in_implementing && line.starts_with("- **") {
            if let Some(id) = extract_gap_id(line) {
                let is_placeholder = id.contains("NEW")
                    || id.contains("XXX")
                    || id.contains('-') && {
                        let suffix = id.split_once('-').map(|x| x.1).unwrap_or("");
                        suffix == "NEW" || suffix == "XXX"
                    };
                w.gaps.push(RoadmapGap {
                    is_placeholder,
                    status: if is_placeholder {
                        "not_filed".to_string()
                    } else {
                        "open".to_string()
                    },
                    id,
                    closed_pr: None,
                });
            }
        }
    }

    if let Some(w) = current_week {
        weeks.push(w);
    }

    weeks
}

fn extract_gap_id(line: &str) -> Option<String> {
    let after = line.strip_prefix("- **")?;
    let end = after.find("**")?;
    let id = after[..end].trim();
    if id.contains('-') {
        Some(id.to_string())
    } else {
        None
    }
}

pub fn build_report(repo_root: &Path) -> RoadmapStatusReport {
    let roadmap_path = repo_root.join("docs").join("ROADMAP.md");
    let content = std::fs::read_to_string(&roadmap_path).unwrap_or_default();
    let mut weeks = parse_roadmap(&content);

    let mut untraced_p0: Vec<String> = Vec::new();
    let mut pillar_coverage = PillarCoverage::default();
    let mut outcome_drift: Vec<OutcomeDrift> = Vec::new();

    if let Ok(gs) = crate::gap_store::GapStore::open(repo_root) {
        let all_open = gs.list(Some("open")).unwrap_or_default();
        let all_done = gs.list(Some("done")).unwrap_or_default();

        for week in &mut weeks {
            for gap in &mut week.gaps {
                if gap.is_placeholder {
                    continue;
                }
                if let Some(row) = all_done.iter().find(|r| r.id == gap.id) {
                    gap.status = "shipped".to_string();
                    gap.closed_pr = row.closed_pr;
                } else if all_open.iter().any(|r| r.id == gap.id) {
                    gap.status = "open".to_string();
                }
                // gaps not found in either list stay "open" (conservative)
            }
        }

        // MISSION-008: when outcomes exist, a gap with a non-null outcome_id FK
        // is considered "traced" even if its ID doesn't appear in ROADMAP.md.
        // This replaces the regex-over-ROADMAP.md path for traced gaps while
        // keeping the ROADMAP.md regex as fallback when outcomes table is empty.
        let outcomes = gs.list_outcomes().unwrap_or_default();
        let use_outcome_join = !outcomes.is_empty();

        // META-1045: outcome-table drift, inside this same command (no parallel checker).
        let done_ids: std::collections::HashSet<String> =
            all_done.iter().map(|r| r.id.clone()).collect();
        outcome_drift = analyze_outcome_drift(&outcomes, &all_open, &done_ids);

        // INFRA-1145: collect all gap IDs referenced in the roadmap.
        let all_roadmap_ids: std::collections::HashSet<String> = weeks
            .iter()
            .flat_map(|w| w.gaps.iter())
            .filter(|g| !g.is_placeholder)
            .map(|g| g.id.clone())
            .collect();

        // INFRA-1145 / MISSION-008: untraced_p0 — open P0/P1 gaps not traced.
        // A gap is traced if it appears in a ROADMAP.md week (original path) OR
        // has a non-null outcome_id FK (new path; only active when outcomes exist).
        for row in &all_open {
            let priority = row.priority.as_str();
            if priority == "P0" || priority == "P1" {
                let in_roadmap = all_roadmap_ids.contains(&row.id);
                let has_outcome_fk = use_outcome_join
                    && row
                        .outcome_id
                        .as_ref()
                        .map(|s| !s.is_empty())
                        .unwrap_or(false);
                if !in_roadmap && !has_outcome_fk {
                    untraced_p0.push(row.id.clone());
                }
            }
        }

        // INFRA-1145 / CREDIBLE-238: pillar_coverage — count open gaps by pillar tag in title or R&D domain.
        for row in &all_open {
            let title = row.title.as_str();
            let title_up = title.to_uppercase();
            if row.domain.eq_ignore_ascii_case("RND")
                || row.domain.eq_ignore_ascii_case("R&D")
                || row.id.starts_with("RND-")
                || title_up.contains("R&D")
                || title_up.starts_with("RND:")
            {
                pillar_coverage.rnd += 1;
            }
            if title.contains("EFFECTIVE") {
                pillar_coverage.effective += 1;
            } else if title.contains("CREDIBLE") {
                pillar_coverage.credible += 1;
            } else if title.contains("RESILIENT") {
                pillar_coverage.resilient += 1;
            } else if title.contains("ZERO-WASTE") {
                pillar_coverage.zero_waste += 1;
            }
        }
    }

    // INFRA-1145: starved_outcomes — weeks where zero gaps are shipped or in-flight.
    let starved_outcomes: Vec<u32> = weeks
        .iter()
        .filter(|w| {
            !w.gaps.is_empty()
                && w.gaps
                    .iter()
                    .all(|g| g.status != "shipped" && g.status != "in_flight")
        })
        .map(|w| w.week)
        .collect();

    RoadmapStatusReport {
        weeks,
        ts: current_iso8601(),
        starved_outcomes,
        untraced_p0,
        pillar_coverage,
        outcome_drift,
    }
}

fn outcome_status_icon(week: &WeekOutcome) -> &'static str {
    if week.gaps.is_empty() {
        return "🟡";
    }
    let total = week.gaps.len();
    let shipped = week.gaps.iter().filter(|g| g.status == "shipped").count();
    let in_flight = week.gaps.iter().filter(|g| g.status == "in_flight").count();

    if shipped == total {
        "🟢"
    } else if shipped + in_flight == 0 {
        "🔴"
    } else {
        "🟡"
    }
}

impl RoadmapStatusReport {
    /// Returns true when drift is detected (starved outcomes or untraced P0/P1 gaps).
    pub fn has_drift(&self) -> bool {
        !self.starved_outcomes.is_empty()
            || !self.untraced_p0.is_empty()
            || !self.outcome_drift.is_empty()
    }

    pub fn render_text(&self) -> String {
        self.render_text_with_opts(usize::MAX)
    }

    pub fn render_text_with_opts(&self, top_starved: usize) -> String {
        let mut out = String::new();
        out.push_str("═══ Roadmap Status ═══\n\n");

        for week in &self.weeks {
            let icon = outcome_status_icon(week);
            out.push_str(&format!(
                "{} Week {} — {}\n",
                icon, week.week, week.week_title
            ));
            if !week.outcome.is_empty() {
                out.push_str(&format!("   Outcome: {}\n", week.outcome));
            }

            let shipped: Vec<_> = week.gaps.iter().filter(|g| g.status == "shipped").collect();
            let in_flight: Vec<_> = week
                .gaps
                .iter()
                .filter(|g| g.status == "in_flight")
                .collect();
            let open: Vec<_> = week.gaps.iter().filter(|g| g.status == "open").collect();
            let not_filed: Vec<_> = week
                .gaps
                .iter()
                .filter(|g| g.status == "not_filed")
                .collect();

            out.push_str(&format!(
                "   Gaps: {} shipped, {} in-flight, {} open, {} not-filed\n",
                shipped.len(),
                in_flight.len(),
                open.len(),
                not_filed.len()
            ));

            for g in &shipped {
                let pr = g.closed_pr.map(|p| format!(" (#{p})")).unwrap_or_default();
                out.push_str(&format!("   \u{2705} {} shipped{}\n", g.id, pr));
            }
            for g in &in_flight {
                out.push_str(&format!("   \u{1f504} {} in-flight\n", g.id));
            }
            for g in &open {
                out.push_str(&format!("   \u{2b1c} {} open\n", g.id));
            }
            for g in &not_filed {
                out.push_str(&format!(
                    "   \u{1f4cb} {} (placeholder \u{2014} not filed)\n",
                    g.id
                ));
            }
            out.push('\n');
        }

        // INFRA-1145: drift analysis section
        out.push_str("─── Drift Analysis (INFRA-1145) ───\n");

        let shown_starved: Vec<_> = self.starved_outcomes.iter().take(top_starved).collect();
        if shown_starved.is_empty() {
            out.push_str(
                "  \u{2705} No starved outcomes (all weeks have \u{2265}1 shipped/in-flight gap)\n",
            );
        } else {
            out.push_str(&format!(
                "  \u{26a0}\u{fe0f}  Starved outcomes: {} week(s) with zero progress\n",
                self.starved_outcomes.len()
            ));
            for w in &shown_starved {
                out.push_str(&format!("     Week {}\n", w));
            }
            if self.starved_outcomes.len() > top_starved {
                out.push_str(&format!(
                    "     \u{2026} {} more (use --top-starved to adjust)\n",
                    self.starved_outcomes.len() - top_starved
                ));
            }
        }

        if self.untraced_p0.is_empty() {
            out.push_str(
                "  \u{2705} No untraced P0/P1 gaps (all P0/P1 appear in ROADMAP outcomes)\n",
            );
        } else {
            out.push_str(&format!(
                "  \u{26a0}\u{fe0f}  Untraced P0/P1 gaps: {} not in any ROADMAP week\n",
                self.untraced_p0.len()
            ));
            for id in &self.untraced_p0 {
                out.push_str(&format!("     {}\n", id));
            }
        }

        // META-1045: outcome-table drift.
        if self.outcome_drift.is_empty() {
            out.push_str(
                "  \u{2705} No outcome-table drift (every live outcome with a DoD has a pickable open gap)\n",
            );
        } else {
            out.push_str(&format!(
                "  \u{26a0}\u{fe0f}  Outcome-table drift: {} live outcome(s) with a DoD but nothing pickable\n",
                self.outcome_drift.len()
            ));
            for d in &self.outcome_drift {
                out.push_str(&format!(
                    "     {} [{}] {} — {}\n",
                    d.outcome_id, d.kind, d.title, d.detail
                ));
            }
        }

        let pc = &self.pillar_coverage;
        out.push_str(&format!(
            "  Pillar coverage (open): EFFECTIVE={} CREDIBLE={} RESILIENT={} ZERO-WASTE={} R&D={}\n",
            pc.effective, pc.credible, pc.resilient, pc.zero_waste, pc.rnd
        ));

        out.push('\n');
        out.push_str(&format!("Generated: {}\n", self.ts));
        out
    }

    pub fn render_json(&self) -> String {
        self.render_json_with_opts(usize::MAX)
    }

    pub fn render_json_with_opts(&self, top_starved: usize) -> String {
        let mut weeks_json: Vec<String> = Vec::new();
        for week in &self.weeks {
            let icon = outcome_status_icon(week);
            let shipped = week.gaps.iter().filter(|g| g.status == "shipped").count();
            let in_flight = week.gaps.iter().filter(|g| g.status == "in_flight").count();
            let open = week.gaps.iter().filter(|g| g.status == "open").count();
            let not_filed = week.gaps.iter().filter(|g| g.status == "not_filed").count();

            let gaps_json: Vec<String> = week
                .gaps
                .iter()
                .map(|g| {
                    let pr = g
                        .closed_pr
                        .map(|p| format!(r#","closed_pr":{p}"#))
                        .unwrap_or_default();
                    format!(
                        r#"{{"id":"{}","is_placeholder":{},"status":"{}"{}}}"#,
                        g.id, g.is_placeholder, g.status, pr
                    )
                })
                .collect();

            weeks_json.push(format!(
                r#"{{"week":{week},"week_title":"{wt}","outcome":"{oc}","status_icon":"{icon}","shipped":{shipped},"in_flight":{in_flight},"open":{open},"not_filed":{not_filed},"gaps":[{gaps}]}}"#,
                week = week.week,
                wt = escape_json(&week.week_title),
                oc = escape_json(&week.outcome),
                icon = icon,
                shipped = shipped,
                in_flight = in_flight,
                open = open,
                not_filed = not_filed,
                gaps = gaps_json.join(","),
            ));
        }

        // INFRA-1145: new fields
        let starved_json: Vec<String> = self
            .starved_outcomes
            .iter()
            .take(top_starved)
            .map(|w| w.to_string())
            .collect();

        let untraced_json: Vec<String> = self
            .untraced_p0
            .iter()
            .map(|id| format!(r#""{id}""#))
            .collect();

        let pc = &self.pillar_coverage;
        let pillar_json = format!(
            r#"{{"effective":{e},"credible":{c},"resilient":{r},"zero_waste":{z},"rnd":{rnd}}}"#,
            e = pc.effective,
            c = pc.credible,
            r = pc.resilient,
            z = pc.zero_waste,
            rnd = pc.rnd,
        );

        let outcome_drift_json: Vec<String> = self
            .outcome_drift
            .iter()
            .map(|d| {
                format!(
                    r#"{{"outcome_id":"{}","title":"{}","kind":"{}","detail":"{}","open_children":{}}}"#,
                    escape_json(&d.outcome_id),
                    escape_json(&d.title),
                    d.kind,
                    escape_json(&d.detail),
                    d.open_children
                )
            })
            .collect();

        format!(
            r#"{{"ts":"{ts}","kind":"roadmap_status","weeks":[{weeks}],"starved_outcomes":[{starved}],"untraced_p0":[{untraced}],"pillar_coverage":{pillar},"outcome_drift":[{outcome_drift}]}}"#,
            ts = self.ts,
            weeks = weeks_json.join(","),
            starved = starved_json.join(","),
            untraced = untraced_json.join(","),
            pillar = pillar_json,
            outcome_drift = outcome_drift_json.join(","),
        )
    }
}

fn escape_json(s: &str) -> String {
    s.replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('\n', "\\n")
        .replace('\r', "\\r")
}

fn current_iso8601() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let out = std::process::Command::new("date")
        .args(["-u", "-r", &secs.to_string(), "+%Y-%m-%dT%H:%M:%SZ"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .and_then(|o| String::from_utf8(o.stdout).ok());
    if let Some(s) = out {
        return s.trim().to_string();
    }
    let out2 = std::process::Command::new("date")
        .args(["-u", "+%Y-%m-%dT%H:%M:%SZ"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .and_then(|o| String::from_utf8(o.stdout).ok());
    out2.map(|s| s.trim().to_string())
        .unwrap_or_else(|| secs.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURE: &str = "## Week 1 \u{2014} User-facing front door (May 6 \u{2192} 13)\n\n**Outcome.** A solo dev with Ollama can run chump gen and get a working PR.\n\n**Implementing gaps:**\n- **INFRA-100** \u{2014} gap one (P0 m, pickable)\n- **INFRA-101** \u{2014} gap two (P1 s, in flight #1000)\n- **INFRA-NEW** \u{2014} gap three \u{2014} to be filed\n\n---\n\n## Week 2 \u{2014} Credible evidence (May 14 \u{2192} 21)\n\n**Outcome.** Published numbers showing whether the cognition stack helps.\n\n**Implementing gaps:**\n- **EVAL-200** \u{2014} eval gap (P1 m, pickable)\n- **INFRA-XXX** \u{2014} placeholder gap \u{2014} to be filed\n";

    #[test]
    fn test_parse_week_count() {
        let weeks = parse_roadmap(FIXTURE);
        assert_eq!(weeks.len(), 2);
    }

    #[test]
    fn test_parse_week1_gap_ids() {
        let weeks = parse_roadmap(FIXTURE);
        assert_eq!(weeks[0].week, 1);
        let ids: Vec<&str> = weeks[0].gaps.iter().map(|g| g.id.as_str()).collect();
        assert!(ids.contains(&"INFRA-100"));
        assert!(ids.contains(&"INFRA-101"));
        assert!(ids.contains(&"INFRA-NEW"));
    }

    #[test]
    fn test_placeholder_detection() {
        let weeks = parse_roadmap(FIXTURE);
        let new_gap = weeks[0].gaps.iter().find(|g| g.id == "INFRA-NEW").unwrap();
        assert!(new_gap.is_placeholder);
        let real_gap = weeks[0].gaps.iter().find(|g| g.id == "INFRA-100").unwrap();
        assert!(!real_gap.is_placeholder);
    }

    #[test]
    fn test_outcome_text_extracted() {
        let weeks = parse_roadmap(FIXTURE);
        assert!(weeks[0].outcome.contains("solo dev"));
    }

    #[test]
    fn test_icon_red_all_open() {
        let week = WeekOutcome {
            week: 1,
            week_title: "test".to_string(),
            outcome: String::new(),
            gaps: vec![RoadmapGap {
                id: "INFRA-1".to_string(),
                is_placeholder: false,
                status: "open".to_string(),
                closed_pr: None,
            }],
        };
        assert_eq!(outcome_status_icon(&week), "🔴");
    }

    #[test]
    fn test_icon_green_all_shipped() {
        let week = WeekOutcome {
            week: 1,
            week_title: "test".to_string(),
            outcome: String::new(),
            gaps: vec![RoadmapGap {
                id: "INFRA-1".to_string(),
                is_placeholder: false,
                status: "shipped".to_string(),
                closed_pr: Some(1234),
            }],
        };
        assert_eq!(outcome_status_icon(&week), "🟢");
    }

    #[test]
    fn test_icon_yellow_partial() {
        let week = WeekOutcome {
            week: 1,
            week_title: "test".to_string(),
            outcome: String::new(),
            gaps: vec![
                RoadmapGap {
                    id: "INFRA-1".to_string(),
                    is_placeholder: false,
                    status: "shipped".to_string(),
                    closed_pr: None,
                },
                RoadmapGap {
                    id: "INFRA-2".to_string(),
                    is_placeholder: false,
                    status: "open".to_string(),
                    closed_pr: None,
                },
            ],
        };
        assert_eq!(outcome_status_icon(&week), "🟡");
    }

    #[test]
    fn test_render_json_required_fields() {
        let report = RoadmapStatusReport {
            weeks: vec![],
            ts: "2026-05-06T17:00:00Z".to_string(), // chump-fmt: time-bomb-ok
            ..Default::default()
        };
        let json = report.render_json();
        assert!(json.contains(r#""kind":"roadmap_status""#));
        assert!(json.contains(r#""weeks""#));
        assert!(json.contains(r#""ts""#));
        // INFRA-1145: new required fields
        assert!(json.contains(r#""starved_outcomes""#));
        assert!(json.contains(r#""untraced_p0""#));
        assert!(json.contains(r#""pillar_coverage""#));
    }

    #[test]
    fn test_render_text_week_headers() {
        let weeks = parse_roadmap(FIXTURE);
        let report = RoadmapStatusReport {
            weeks,
            ts: "2026-05-06T17:00:00Z".to_string(), // chump-fmt: time-bomb-ok
            ..Default::default()
        };
        let text = report.render_text();
        assert!(text.contains("Week 1"));
        assert!(text.contains("Week 2"));
    }

    #[test]
    fn test_render_text_not_filed_label() {
        let weeks = parse_roadmap(FIXTURE);
        let report = RoadmapStatusReport {
            weeks,
            ts: "2026-05-06T17:00:00Z".to_string(), // chump-fmt: time-bomb-ok
            ..Default::default()
        };
        let text = report.render_text();
        assert!(
            text.contains("not-filed") || text.contains("not_filed") || text.contains("not filed")
        );
    }

    // INFRA-1145: tests for new drift analysis fields
    #[test]
    fn test_starved_outcomes_all_open() {
        let week = WeekOutcome {
            week: 5,
            week_title: "test".to_string(),
            outcome: "some outcome".to_string(),
            gaps: vec![RoadmapGap {
                id: "INFRA-1".to_string(),
                is_placeholder: false,
                status: "open".to_string(),
                closed_pr: None,
            }],
        };
        let report = RoadmapStatusReport {
            weeks: vec![week],
            ts: "2026-05-06T17:00:00Z".to_string(), // chump-fmt: time-bomb-ok
            starved_outcomes: vec![5],
            ..Default::default()
        };
        assert!(report.has_drift());
        let json = report.render_json();
        assert!(json.contains(r#""starved_outcomes":[5]"#));
        let text = report.render_text();
        assert!(text.contains("Starved") || text.contains("starved"));
    }

    #[test]
    fn test_no_drift_all_shipped() {
        let report = RoadmapStatusReport {
            weeks: vec![],
            ts: "2026-05-06T17:00:00Z".to_string(), // chump-fmt: time-bomb-ok
            starved_outcomes: vec![],
            untraced_p0: vec![],
            pillar_coverage: PillarCoverage::default(),
            outcome_drift: vec![],
        };
        assert!(!report.has_drift());
    }

    #[test]
    fn test_untraced_p0_in_json() {
        let report = RoadmapStatusReport {
            weeks: vec![],
            ts: "2026-05-06T17:00:00Z".to_string(), // chump-fmt: time-bomb-ok
            untraced_p0: vec!["INFRA-999".to_string()],
            ..Default::default()
        };
        assert!(report.has_drift());
        let json = report.render_json();
        assert!(json.contains(r#""untraced_p0":["INFRA-999"]"#));
    }

    #[test]
    fn test_top_starved_limits_output() {
        let report = RoadmapStatusReport {
            weeks: vec![],
            ts: "2026-05-06T17:00:00Z".to_string(), // chump-fmt: time-bomb-ok
            starved_outcomes: vec![1, 2, 3, 4, 5],
            ..Default::default()
        };
        // With top_starved=2, JSON should only show 2 entries
        let json = report.render_json_with_opts(2);
        // Should show [1,2] not [1,2,3,4,5]
        assert!(json.contains(r#""starved_outcomes":[1,2]"#));
    }

    #[test]
    fn test_pillar_coverage_in_json() {
        let report = RoadmapStatusReport {
            weeks: vec![],
            ts: "2026-05-06T17:00:00Z".to_string(), // chump-fmt: time-bomb-ok
            pillar_coverage: PillarCoverage {
                effective: 5,
                credible: 3,
                resilient: 7,
                zero_waste: 2,
                rnd: 1,
            },
            ..Default::default()
        };
        let json = report.render_json();
        assert!(json.contains(r#""effective":5"#));
        assert!(json.contains(r#""credible":3"#));
        assert!(json.contains(r#""resilient":7"#));
        assert!(json.contains(r#""zero_waste":2"#));
        assert!(json.contains(r#""rnd":1"#));
    }

    #[test]
    fn test_week2_xxx_placeholder() {
        let weeks = parse_roadmap(FIXTURE);
        let xxx = weeks[1].gaps.iter().find(|g| g.id == "INFRA-XXX").unwrap();
        assert!(xxx.is_placeholder);
        assert_eq!(xxx.status, "not_filed");
    }

    // ── META-1045: outcome-table drift ─────────────────────────────────────

    fn outcome(id: &str, status: &str, dod: &str) -> crate::gap_store::OutcomeRow {
        crate::gap_store::OutcomeRow {
            id: id.to_string(),
            title: format!("{id} lighthouse"),
            priority: "P1".to_string(),
            definition_of_done: dod.to_string(),
            status: status.to_string(),
            created_at: 0,
            closed_at: None,
            park_reason: None,
            jtbd_who: None,
            jtbd_struggling_moment: None,
            jtbd_done_signal: None,
        }
    }

    fn open_gap(id: &str, outcome: &str, depends_on: &str) -> crate::gap_store::GapRow {
        crate::gap_store::GapRow {
            id: id.to_string(),
            domain: "PRODUCT".to_string(),
            title: "t".to_string(),
            description: String::new(),
            priority: "P1".to_string(),
            effort: "s".to_string(),
            status: "open".to_string(),
            acceptance_criteria: String::new(),
            depends_on: depends_on.to_string(),
            notes: String::new(),
            source_doc: String::new(),
            created_at: 0,
            closed_at: None,
            opened_date: String::new(),
            closed_date: String::new(),
            closed_pr: None,
            skills_required: String::new(),
            preferred_backend: String::new(),
            preferred_machine: String::new(),
            estimated_minutes: String::new(),
            required_model: String::new(),
            shipped_in: None,
            outcome_id: Some(outcome.to_string()),
            evidence: None,
        }
    }

    /// The 2026-08-07 case: three product lighthouse outcomes holding 0 / 0 / 1
    /// gaps. Two are empty; the one gap the third holds is blocked by an open
    /// dependency, so nothing under any of them is pickable.
    #[test]
    fn meta_1045_lighthouse_0_0_1_case_is_flagged() {
        let outcomes = vec![
            outcome("PRODUCT-LH-1", "open", "Smuggler loop runs end-to-end"),
            outcome("PRODUCT-LH-2", "open", "Olive checkout converts"),
            outcome("PRODUCT-LH-3", "open", "Games site ships a playable demo"),
        ];
        let open = vec![
            open_gap("PRODUCT-101", "PRODUCT-LH-3", "PRODUCT-100"),
            open_gap("PRODUCT-100", "OTHER-OUTCOME", ""),
        ];
        let done: std::collections::HashSet<String> = std::collections::HashSet::new();
        let drift = analyze_outcome_drift(&outcomes, &open, &done);
        let got: Vec<(&str, &str)> = drift
            .iter()
            .map(|d| (d.outcome_id.as_str(), d.kind))
            .collect();
        assert_eq!(
            got,
            vec![
                ("PRODUCT-LH-1", "no_open_gaps"),
                ("PRODUCT-LH-2", "no_open_gaps"),
                ("PRODUCT-LH-3", "all_unpickable"),
            ]
        );
        assert_eq!(drift[2].open_children, 1);
        assert!(drift[2]
            .detail
            .contains("PRODUCT-101 blocked by PRODUCT-100"));
    }

    #[test]
    fn meta_1045_healthy_parked_done_and_dod_less_outcomes_are_not_flagged() {
        let outcomes = vec![
            outcome("O-OK", "open", "has a pickable child"),
            outcome("O-DONE", "done", "finished"),
            outcome("O-PARKED", "parked", "deliberately parked"),
            outcome("O-NO-DOD", "open", "   "),
            outcome("O-MIXED", "open", "one blocked, one pickable"),
        ];
        let open = vec![
            open_gap("G-1", "O-OK", ""),
            open_gap("G-2", "O-MIXED", "G-NOT-DONE"),
            open_gap("G-3", "O-MIXED", "G-FINISHED"),
        ];
        let done: std::collections::HashSet<String> =
            ["G-FINISHED".to_string()].into_iter().collect();
        assert!(analyze_outcome_drift(&outcomes, &open, &done).is_empty());
    }

    #[test]
    fn meta_1045_dependency_forms_and_done_deps() {
        assert_eq!(dep_ids(""), Vec::<String>::new());
        assert_eq!(dep_ids(r#"["A-1","B-2"]"#), vec!["A-1", "B-2"]);
        assert_eq!(dep_ids("A-1, B-2"), vec!["A-1", "B-2"]);
        // A dependency that is done does not block.
        let outcomes = vec![outcome("O-1", "open", "dod")];
        let open = vec![open_gap("G-1", "O-1", "A-1")];
        let done: std::collections::HashSet<String> = ["A-1".to_string()].into_iter().collect();
        assert!(analyze_outcome_drift(&outcomes, &open, &done).is_empty());
    }

    #[test]
    fn meta_1045_outcome_drift_trips_has_drift_and_renders() {
        let report = RoadmapStatusReport {
            ts: "2026-08-07T00:00:00Z".to_string(), // chump-fmt: time-bomb-ok
            outcome_drift: vec![OutcomeDrift {
                outcome_id: "O-1".to_string(),
                title: "Lighthouse".to_string(),
                kind: "no_open_gaps",
                detail: "has a stated definition of done but zero open gaps".to_string(),
                open_children: 0,
            }],
            ..Default::default()
        };
        assert!(
            report.has_drift(),
            "outcome drift alone must count as drift"
        );
        assert!(report.render_text().contains("Outcome-table drift: 1"));
        let json = report.render_json();
        assert!(json.contains(r#""outcome_drift":[{"outcome_id":"O-1""#));
        assert!(json.contains(r#""kind":"no_open_gaps""#));
        assert!(!RoadmapStatusReport::default().has_drift());
    }
}
