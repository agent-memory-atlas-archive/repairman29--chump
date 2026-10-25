//! JSON output for `chump-plan --format json`.
//!
//! Emits a single JSON object suitable for `.chump-locks/gap-priority.json`
//! consumption by the fleet picker (INFRA-1258). Schema is intentionally
//! minimal and stable — picker logic should depend only on the documented
//! fields below.
//!
//! Schema:
//! ```json
//! {
//!   "generated_at": "2026-05-14T16:35:00Z",
//!   "planner_version": "0.1.0",
//!   "weights_identity": "<sha256-16>",
//!   "items": [
//!     {
//!       "rank": 1,
//!       "gap_id": "INFRA-1237",
//!       "score": 12.4,
//!       "domain": "INFRA",
//!       "pillar": "CREDIBLE",
//!       "priority": "P0",
//!       "effort": "m",
//!       "title": "...",
//!       "unblocks_count": 3,
//!       "layer": 0,
//!       "critical_path_days": 4.5,
//!       "prerequisites": []
//!     },
//!     ...
//!   ]
//! }
//! ```
//!
//! Field semantics (INFRA-1281):
//!   - `layer`: 0 = no OPEN prerequisites (foundation). N = max(layer of
//!     open prereqs) + 1. Picker uses this to enforce tier ordering —
//!     drain layer 0 before workers race onto layer 1+ siblings.
//!   - `critical_path_days`: longest forward chain of `Effort::days()`
//!     from this gap through all transitive open dependents to a leaf.
//!     Highlights gaps that gate the longest wall-clock chain.

use crate::plan::PlanItem;
use crate::score::Weights;
use sha2::{Digest, Sha256};
use std::io::Write;

/// Stable hash of the weight values so consumers can detect when the
/// scoring tuning has changed (and snapshots / dashboards need refresh).
pub fn weights_identity(w: &Weights) -> String {
    let payload = format!(
        "p0={} p1={} p2={} p3={} unblock={} xs={} s={} m={} l={} xl={} age={} road={} cap={} fail={} stale={}",
        w.p0, w.p1, w.p2, w.p3, w.unblocking_bonus,
        w.effort_xs, w.effort_s, w.effort_m, w.effort_l, w.effort_xl,
        w.cycle_age, w.roadmap_alignment, w.pillar_cap_penalty,
        w.recent_failure, w.stale_doc_penalty,
    );
    let mut hasher = Sha256::new();
    hasher.update(payload.as_bytes());
    let bytes = hasher.finalize();
    bytes.iter().take(8).map(|b| format!("{:02x}", b)).collect()
}

pub fn render_json<W: Write>(
    items: &[PlanItem],
    weights: &Weights,
    writer: &mut W,
) -> std::io::Result<()> {
    let now = chrono::Utc::now();
    writer.write_all(b"{\n")?;
    writeln!(writer, "  \"version\": \"0.2\",")?;
    writeln!(
        writer,
        "  \"generated_at\": \"{}\",",
        now.format("%Y-%m-%dT%H:%M:%SZ")
    )?;
    writeln!(
        writer,
        "  \"planner_version\": \"{}\",",
        env!("CARGO_PKG_VERSION")
    )?;
    writeln!(
        writer,
        "  \"weights_identity\": \"{}\",",
        weights_identity(weights)
    )?;
    writer.write_all(b"  \"items\": [\n")?;
    let last = items.len().saturating_sub(1);
    for (idx, item) in items.iter().enumerate() {
        let comma = if idx == last { "" } else { "," };
        let priority = item.gap.priority.as_str();
        let effort = item.gap.effort.as_str();
        let prereqs = item
            .prerequisites
            .iter()
            .map(|g| format!("\"{}\"", json_escape(&g.0)))
            .collect::<Vec<_>>()
            .join(",");
        writeln!(writer, "    {{")?;
        writeln!(writer, "      \"rank\": {},", idx + 1)?;
        writeln!(
            writer,
            "      \"gap_id\": \"{}\",",
            json_escape(&item.gap.id.0)
        )?;
        writeln!(writer, "      \"score\": {:.4},", item.score.total)?;
        writeln!(
            writer,
            "      \"domain\": \"{}\",",
            json_escape(&format!("{:?}", item.gap.domain))
        )?;
        writeln!(writer, "      \"priority\": \"{}\",", priority)?;
        writeln!(writer, "      \"effort\": \"{}\",", effort)?;
        writeln!(
            writer,
            "      \"title\": \"{}\",",
            json_escape(&item.gap.title)
        )?;
        writeln!(writer, "      \"unblocks\": {},", item.score.unblocks_count)?;
        writeln!(
            writer,
            "      \"unblocks_count\": {},",
            item.score.unblocks_count
        )?;
        writeln!(writer, "      \"layer\": {},", item.layer)?;
        writeln!(
            writer,
            "      \"critical_path_days\": {:.4},",
            item.critical_path_days
        )?;
        writeln!(writer, "      \"prerequisites\": [{}]", prereqs)?;
        writeln!(writer, "    }}{}", comma)?;
    }
    writer.write_all(b"  ]\n}\n")?;
    Ok(())
}

fn json_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parses_as_json(bytes: &[u8]) -> serde_yaml::Value {
        // serde_yaml accepts JSON as a subset — handy because the crate
        // already depends on it. Avoids adding serde_json just for tests.
        serde_yaml::from_slice(bytes).expect("output must parse as JSON")
    }

    #[test]
    fn json_escape_meta_chars() {
        assert_eq!(json_escape("a\"b"), "a\\\"b");
        assert_eq!(json_escape("a\\b"), "a\\\\b");
        assert_eq!(json_escape("line1\nline2"), "line1\\nline2");
    }

    #[test]
    fn render_empty_items_yields_valid_json() {
        let weights = Weights::default();
        let mut buf = Vec::new();
        render_json(&[], &weights, &mut buf).unwrap();
        let s = String::from_utf8(buf).unwrap();
        assert!(s.contains("\"version\": \"0.2\""));
        assert!(s.contains("\"items\": [\n"));
        assert!(s.contains("\"weights_identity\""));
        let _ = parses_as_json(s.as_bytes());
    }

    #[test]
    fn render_json_v02_schema_and_high_unblock_ranking() {
        use crate::{
            build_plan, gap::load_str, score::TelemetryInputs, DependencyGraph, Gap, PlanRequest,
        };
        let high_unblk: Gap = load_str(
            "- id: INFRA-HIGH\n  domain: INFRA\n  title: foundation unblock\n  status: open\n  priority: P1\n  effort: s\n",
        )
        .unwrap();
        let low_unblk: Gap = load_str(
            "- id: INFRA-LOW\n  domain: INFRA\n  title: standalone item\n  status: open\n  priority: P1\n  effort: s\n",
        )
        .unwrap();
        let dep1: Gap = load_str(
            "- id: INFRA-D1\n  domain: INFRA\n  title: dep 1\n  status: open\n  priority: P1\n  effort: s\n  depends_on: [INFRA-HIGH]\n",
        )
        .unwrap();
        let dep2: Gap = load_str(
            "- id: INFRA-D2\n  domain: INFRA\n  title: dep 2\n  status: open\n  priority: P1\n  effort: s\n  depends_on: [INFRA-HIGH]\n",
        )
        .unwrap();
        let gaps = vec![low_unblk, high_unblk, dep1, dep2];
        let graph = DependencyGraph::build(&gaps);
        let weights = Weights::default();
        let today = chrono::NaiveDate::from_ymd_opt(2026, 5, 14).unwrap();
        let plan = build_plan(
            &gaps,
            &graph,
            &PlanRequest::default(),
            &TelemetryInputs::default(),
            today,
            &weights,
        );
        let mut buf = Vec::new();
        render_json(&plan, &weights, &mut buf).unwrap();
        let val = parses_as_json(&buf);
        assert_eq!(val["version"].as_str(), Some("0.2"));
        assert!(val["generated_at"].as_str().is_some());
        let items = val["items"].as_sequence().expect("items sequence");
        assert!(!items.is_empty());
        assert_eq!(items[0]["gap_id"].as_str(), Some("INFRA-HIGH"));
        assert_eq!(items[0]["rank"].as_u64(), Some(1));
        assert_eq!(items[0]["unblocks"].as_u64(), Some(2));
        assert_eq!(items[0]["priority"].as_str(), Some("P1"));
        assert_eq!(items[0]["effort"].as_str(), Some("s"));
    }
}
