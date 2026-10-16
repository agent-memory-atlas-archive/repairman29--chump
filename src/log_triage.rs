//! INFRA-1891: `chump fleet log-triage` — daily structured pass over the
//! last 24h of `.chump-locks/ambient.jsonl`, cross-referenced against
//! `state.db`, producing a bounded (<=5) Markdown/JSON triage report.
//!
//! Replaces the ad-hoc "maybe I should review the logs" habit with a
//! deterministic scan: histogram the event stream, cross-reference the
//! three known noisy-detector kinds against ground truth, dedup each
//! candidate finding against the open gap registry, and cap the
//! operator-attention budget at 5 findings per day.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::time::Duration;

use chump_gap_store::GapStore;

/// One candidate finding surfaced by the triage pass.
#[derive(Debug, Clone, serde::Serialize)]
pub struct TriageFinding {
    pub signature: String,
    pub evidence: Vec<String>,
    pub cross_ref: String,
    pub dedup_status: String,
    pub suggested_title: String,
    pub suggested_ac: String,
    pub occurrences: u64,
}

/// Full result of one triage pass.
#[derive(Debug, Clone, serde::Serialize)]
pub struct TriageReport {
    pub window_h: u64,
    pub events_processed: u64,
    pub parse_errors: u64,
    pub histogram_top10: Vec<(String, u64)>,
    pub findings: Vec<TriageFinding>,
    pub low_signal_appendix: Vec<TriageFinding>,
    pub rare_threshold: u64,
}

pub struct TriageConfig {
    pub repo_root: PathBuf,
    pub window_h: u64,
    pub rare_threshold: u64,
}

impl TriageConfig {
    pub fn default_for(repo_root: PathBuf) -> Self {
        TriageConfig {
            repo_root,
            window_h: 24,
            rare_threshold: 40,
        }
    }
}

const MAX_MAIN_FINDINGS: usize = 5;
const MAX_EVIDENCE_LINES: usize = 3;

/// Read `.chump-locks/ambient.jsonl`, keep lines within the window, tolerate
/// parse errors (skip + count). Returns raw JSON values plus stats.
fn scan_ambient(
    repo_root: &Path,
    window: Duration,
) -> Result<(Vec<serde_json::Value>, u64, u64), String> {
    let ambient_path = repo_root.join(".chump-locks").join("ambient.jsonl");
    if !ambient_path.exists() {
        return Ok((Vec::new(), 0, 0));
    }
    let raw = std::fs::read_to_string(&ambient_path)
        .map_err(|e| format!("read {}: {}", ambient_path.display(), e))?;
    let cutoff_secs = (std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|e| format!("clock: {}", e))?
        .as_secs())
    .saturating_sub(window.as_secs());

    let mut events = Vec::new();
    let mut processed: u64 = 0;
    let mut parse_errors: u64 = 0;
    for line in raw.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let v: serde_json::Value = match serde_json::from_str(trimmed) {
            Ok(v) => v,
            Err(_) => {
                parse_errors += 1;
                continue;
            }
        };
        if v.get("kind").and_then(|k| k.as_str()).is_none() {
            parse_errors += 1;
            continue;
        }
        if let Some(ts_str) = v.get("ts").and_then(|t| t.as_str()) {
            if let Some(line_secs) = parse_iso8601(ts_str) {
                if line_secs < cutoff_secs {
                    continue;
                }
            }
        }
        processed += 1;
        events.push(v);
    }
    Ok((events, processed, parse_errors))
}

fn parse_iso8601(s: &str) -> Option<u64> {
    use chrono::DateTime;
    let dt = DateTime::parse_from_rfc3339(s).ok()?;
    let secs = dt.timestamp();
    if secs < 0 {
        return None;
    }
    Some(secs as u64)
}

fn event_kind(v: &serde_json::Value) -> &str {
    v.get("kind").and_then(|k| k.as_str()).unwrap_or("")
}

fn event_str_field<'a>(v: &'a serde_json::Value, field: &str) -> Option<&'a str> {
    v.get(field).and_then(|f| f.as_str())
}

/// Token-overlap similarity (0.0-1.0) between two titles. Mirrors the
/// scheme used by `chump gap consolidate` (INFRA-1435) so dedup status is
/// consistent across both surfaces.
fn title_similarity(a: &str, b: &str) -> f64 {
    fn tokens(s: &str) -> std::collections::HashSet<String> {
        s.to_lowercase()
            .split(|c: char| !c.is_alphanumeric())
            .filter(|t| t.len() >= 3)
            .map(String::from)
            .collect()
    }
    let ta = tokens(a);
    let tb = tokens(b);
    if ta.is_empty() || tb.is_empty() {
        return 0.0;
    }
    let intersection = ta.intersection(&tb).count();
    let union = ta.union(&tb).count();
    intersection as f64 / union as f64
}

/// Dedup a candidate title against all open gaps. Returns "none" or
/// "suggested-dup <gap-id>" for the best match >= threshold.
fn dedup_against_open_gaps(store: &GapStore, candidate_title: &str, threshold: f64) -> String {
    let open = match store.list(Some("open")) {
        Ok(g) => g,
        Err(_) => return "none".to_string(),
    };
    let mut best: Option<(String, f64)> = None;
    for g in &open {
        let sim = title_similarity(candidate_title, &g.title);
        if sim >= threshold && best.as_ref().map(|(_, s)| sim > *s).unwrap_or(true) {
            best = Some((g.id.clone(), sim));
        }
    }
    match best {
        Some((id, _)) => format!("suggested-dup {}", id),
        None => "none".to_string(),
    }
}

/// Cross-ref #1: `kind=gap_failed` events whose referenced gap is already
/// `status != open` in state.db — the detector is firing on stale/done gaps.
fn find_gap_failed_on_done(
    events: &[serde_json::Value],
    store: &GapStore,
    dedup_threshold: f64,
) -> Option<TriageFinding> {
    let gap_failed: Vec<&serde_json::Value> = events
        .iter()
        .filter(|v| event_kind(v) == "gap_failed")
        .collect();
    if gap_failed.is_empty() {
        return None;
    }
    let all_gaps = store.list(None).unwrap_or_default();
    let status_of: HashMap<&str, &str> = all_gaps
        .iter()
        .map(|g| (g.id.as_str(), g.status.as_str()))
        .collect();

    let mut hits: Vec<&serde_json::Value> = Vec::new();
    for ev in &gap_failed {
        let gap_id = event_str_field(ev, "gap_id")
            .or_else(|| event_str_field(ev, "gap"))
            .unwrap_or("");
        if gap_id.is_empty() {
            continue;
        }
        match status_of.get(gap_id) {
            Some(status) if *status != "open" => hits.push(ev),
            _ => {}
        }
    }
    if hits.is_empty() {
        return None;
    }
    let evidence: Vec<String> = hits
        .iter()
        .take(MAX_EVIDENCE_LINES)
        .map(|v| v.to_string())
        .collect();
    let title = "gap_failed detector firing on already-done gaps".to_string();
    Some(TriageFinding {
        signature: "gap_failed_on_done_gaps".to_string(),
        evidence,
        cross_ref: format!(
            "{} of {} gap_failed events reference gaps with status != open in state.db",
            hits.len(),
            gap_failed.len()
        ),
        dedup_status: dedup_against_open_gaps(store, &title, dedup_threshold),
        suggested_title: title,
        suggested_ac: "1. Detector that emits kind=gap_failed must check gap status before firing (join gaps.status). 2. No gap_failed emitted for status != open gaps in a 24h soak.".to_string(),
        occurrences: hits.len() as u64,
    })
}

/// Cross-ref #2: `kind=pr_auto_rebase_failed` events whose PR is still
/// DIRTY per the PR cache (`.chump/github_cache.db`, `pr_state` table).
fn find_still_dirty_rebase_failures(
    repo_root: &Path,
    events: &[serde_json::Value],
    store: &GapStore,
    dedup_threshold: f64,
) -> Option<TriageFinding> {
    let rebase_failed: Vec<&serde_json::Value> = events
        .iter()
        .filter(|v| event_kind(v) == "pr_auto_rebase_failed")
        .collect();
    if rebase_failed.is_empty() {
        return None;
    }

    let cache_path = repo_root.join(".chump/github_cache.db");
    let conn = rusqlite::Connection::open_with_flags(
        &cache_path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .ok();

    let mut still_dirty: Vec<&serde_json::Value> = Vec::new();
    let mut cross_ref_note;
    if let Some(conn) = &conn {
        let mut checked = 0u64;
        for ev in &rebase_failed {
            let pr = event_str_field(ev, "pr").unwrap_or("");
            if pr.is_empty() {
                continue;
            }
            let mergeable_state: Option<String> = conn
                .query_row(
                    "SELECT mergeable_state FROM pr_state WHERE number = ?1",
                    [pr],
                    |row| row.get(0),
                )
                .ok();
            checked += 1;
            if mergeable_state.as_deref() == Some("dirty")
                || mergeable_state.as_deref() == Some("DIRTY")
            {
                still_dirty.push(ev);
            }
        }
        cross_ref_note = format!(
            "{} of {} pr_auto_rebase_failed events still show mergeable_state=DIRTY in PR cache ({} checked)",
            still_dirty.len(),
            rebase_failed.len(),
            checked
        );
        if checked == 0 {
            // Table exists but no matching rows — fall back to raw count so
            // the signal isn't silently dropped.
            still_dirty = rebase_failed.clone();
            cross_ref_note = format!(
                "PR cache present but no matching pr_state rows; reporting all {} pr_auto_rebase_failed events unverified",
                rebase_failed.len()
            );
        }
    } else {
        still_dirty = rebase_failed.clone();
        cross_ref_note = format!(
            "PR cache unavailable at {} — reporting all {} pr_auto_rebase_failed events unverified",
            cache_path.display(),
            rebase_failed.len()
        );
    }

    if still_dirty.is_empty() {
        return None;
    }
    let evidence: Vec<String> = still_dirty
        .iter()
        .take(MAX_EVIDENCE_LINES)
        .map(|v| v.to_string())
        .collect();
    let title = "PRs stuck DIRTY after pr_auto_rebase_failed".to_string();
    let _ = &mut cross_ref_note;
    Some(TriageFinding {
        signature: "pr_auto_rebase_failed_still_dirty".to_string(),
        evidence,
        cross_ref: cross_ref_note,
        dedup_status: dedup_against_open_gaps(store, &title, dedup_threshold),
        suggested_title: title,
        suggested_ac: "1. Auto-rebase retry/backoff for PRs still DIRTY N cycles after pr_auto_rebase_failed. 2. Escalate to operator-recall only after retry budget exhausted.".to_string(),
        occurrences: still_dirty.len() as u64,
    })
}

/// Cross-ref #3: `kind=dirty_pr_unresolvable` events grouped by
/// `conflict_files` — flag a hot-file pattern (same file across >=2 PRs).
fn find_hot_conflict_files(
    events: &[serde_json::Value],
    store: &GapStore,
    dedup_threshold: f64,
) -> Option<TriageFinding> {
    let unresolvable: Vec<&serde_json::Value> = events
        .iter()
        .filter(|v| event_kind(v) == "dirty_pr_unresolvable")
        .collect();
    if unresolvable.is_empty() {
        return None;
    }

    // file -> set of PR numbers (or event indices when no `pr` field).
    let mut file_prs: HashMap<String, std::collections::HashSet<String>> = HashMap::new();
    for (idx, ev) in unresolvable.iter().enumerate() {
        let pr = event_str_field(ev, "pr")
            .map(str::to_string)
            .unwrap_or_else(|| format!("ev{idx}"));
        let files_raw = event_str_field(ev, "conflict_files").unwrap_or("");
        for f in files_raw
            .split(',')
            .map(str::trim)
            .filter(|f| !f.is_empty())
        {
            file_prs
                .entry(f.to_string())
                .or_default()
                .insert(pr.clone());
        }
    }
    let hot: Vec<(&String, &std::collections::HashSet<String>)> =
        file_prs.iter().filter(|(_, prs)| prs.len() >= 2).collect();
    if hot.is_empty() {
        return None;
    }
    let mut hot_sorted = hot;
    hot_sorted.sort_by_key(|(_, prs)| std::cmp::Reverse(prs.len()));
    let top_file = hot_sorted[0].0.clone();
    let top_count = hot_sorted[0].1.len();

    let evidence: Vec<String> = unresolvable
        .iter()
        .filter(|ev| {
            event_str_field(ev, "conflict_files")
                .unwrap_or("")
                .contains(top_file.as_str())
        })
        .take(MAX_EVIDENCE_LINES)
        .map(|v| v.to_string())
        .collect();
    let title = format!("Hot-file merge-conflict pattern: {top_file}");
    Some(TriageFinding {
        signature: format!("dirty_pr_unresolvable_hot_file:{top_file}"),
        evidence,
        cross_ref: format!(
            "{} distinct PRs hit unresolvable conflicts on {} ({} hot files total across {} events)",
            top_count,
            top_file,
            hot_sorted.len(),
            unresolvable.len()
        ),
        dedup_status: dedup_against_open_gaps(store, &title, dedup_threshold),
        suggested_title: title,
        suggested_ac: format!("1. Investigate why {top_file} repeatedly produces unresolvable merge conflicts. 2. Propose a structural fix (split file, ownership boundary, or serialized-write lane)."),
        occurrences: top_count as u64,
    })
}

/// Run one triage pass: histogram + cross-referenced findings, capped at
/// `MAX_MAIN_FINDINGS` with overflow routed to a low-signal appendix.
pub fn run_triage(cfg: &TriageConfig) -> Result<TriageReport, String> {
    let window = Duration::from_secs(cfg.window_h.saturating_mul(3600));
    let (events, processed, parse_errors) = scan_ambient(&cfg.repo_root, window)?;

    let mut counts: HashMap<String, u64> = HashMap::new();
    for ev in &events {
        *counts.entry(event_kind(ev).to_string()).or_insert(0) += 1;
    }
    let mut histogram: Vec<(String, u64)> = counts.iter().map(|(k, v)| (k.clone(), *v)).collect();
    histogram.sort_by_key(|(_, c)| std::cmp::Reverse(*c));
    let histogram_top10: Vec<(String, u64)> = histogram.iter().take(10).cloned().collect();

    let rare_kinds: std::collections::HashSet<&String> = counts
        .iter()
        .filter(|(_, c)| **c <= cfg.rare_threshold)
        .map(|(k, _)| k)
        .collect();

    let store = GapStore::open(&cfg.repo_root).map_err(|e| format!("open state.db: {e:#}"))?;
    const DEDUP_THRESHOLD: f64 = 0.7;

    let mut all_findings: Vec<TriageFinding> = Vec::new();
    if rare_kinds.contains(&"gap_failed".to_string()) {
        if let Some(f) = find_gap_failed_on_done(&events, &store, DEDUP_THRESHOLD) {
            all_findings.push(f);
        }
    }
    if rare_kinds.contains(&"pr_auto_rebase_failed".to_string()) {
        if let Some(f) =
            find_still_dirty_rebase_failures(&cfg.repo_root, &events, &store, DEDUP_THRESHOLD)
        {
            all_findings.push(f);
        }
    }
    if rare_kinds.contains(&"dirty_pr_unresolvable".to_string()) {
        if let Some(f) = find_hot_conflict_files(&events, &store, DEDUP_THRESHOLD) {
            all_findings.push(f);
        }
    }

    // Highest-occurrence findings first; overflow past the operator-attention
    // budget goes to the low-signal appendix (AC6).
    all_findings.sort_by_key(|f| std::cmp::Reverse(f.occurrences));
    let (findings, low_signal_appendix) = if all_findings.len() > MAX_MAIN_FINDINGS {
        let overflow = all_findings.split_off(MAX_MAIN_FINDINGS);
        (all_findings, overflow)
    } else {
        (all_findings, Vec::new())
    };

    Ok(TriageReport {
        window_h: cfg.window_h,
        events_processed: processed,
        parse_errors,
        histogram_top10,
        findings,
        low_signal_appendix,
        rare_threshold: cfg.rare_threshold,
    })
}

/// Render the report as Markdown per AC5's required section layout.
pub fn render_markdown(report: &TriageReport, scan_date: &str) -> String {
    let mut out = String::new();
    out.push_str(&format!("# Log triage — {scan_date}\n\n"));

    out.push_str("## Scan window\n\n");
    out.push_str(&format!(
        "- window: last {}h\n- events processed: {}\n- parse errors: {}\n- rare-kind threshold: <= {}\n\n",
        report.window_h, report.events_processed, report.parse_errors, report.rare_threshold
    ));

    out.push_str("## Top-10 event-kind histogram\n\n");
    if report.histogram_top10.is_empty() {
        out.push_str("_(no events in window)_\n\n");
    } else {
        out.push_str("| kind | count |\n|---|---|\n");
        for (k, c) in &report.histogram_top10 {
            out.push_str(&format!("| {k} | {c} |\n"));
        }
        out.push('\n');
    }

    out.push_str(&format!(
        "## Candidate findings ({}/{MAX_MAIN_FINDINGS})\n\n",
        report.findings.len()
    ));
    if report.findings.is_empty() {
        out.push_str("_(no candidate findings this window)_\n\n");
    }
    for (i, f) in report.findings.iter().enumerate() {
        out.push_str(&format!("### {}. {}\n\n", i + 1, f.signature));
        out.push_str(&format!("- occurrences: {}\n", f.occurrences));
        out.push_str(&format!("- cross-ref: {}\n", f.cross_ref));
        out.push_str(&format!("- dedup status: {}\n", f.dedup_status));
        out.push_str(&format!("- suggested gap title: {}\n", f.suggested_title));
        out.push_str(&format!("- suggested AC stub: {}\n", f.suggested_ac));
        out.push_str("- evidence:\n");
        for e in &f.evidence {
            out.push_str(&format!("  - `{e}`\n"));
        }
        out.push('\n');
    }

    if !report.low_signal_appendix.is_empty() {
        out.push_str("## Appendix: low-signal (overflow past operator-attention budget)\n\n");
        for f in &report.low_signal_appendix {
            out.push_str(&format!(
                "- {} (occurrences={}, dedup={})\n",
                f.signature, f.occurrences, f.dedup_status
            ));
        }
        out.push('\n');
    }

    out
}

/// Render the report as JSON (AC7 `--json`).
pub fn render_json(report: &TriageReport) -> serde_json::Value {
    serde_json::json!({
        "window_h": report.window_h,
        "events_processed": report.events_processed,
        "parse_errors": report.parse_errors,
        "rare_threshold": report.rare_threshold,
        "histogram_top10": report.histogram_top10.iter().map(|(k, c)| serde_json::json!({"kind": k, "count": c})).collect::<Vec<_>>(),
        "findings": report.findings,
        "low_signal_appendix": report.low_signal_appendix,
        "candidate_gap_count": report.findings.len() + report.low_signal_appendix.len(),
    })
}

/// Write the Markdown report to `.chump/triage/YYYY-MM-DD.md` and refresh
/// the `today.md` symlink (AC5, AC11).
pub fn write_report(
    repo_root: &Path,
    report: &TriageReport,
    scan_date: &str,
) -> std::io::Result<PathBuf> {
    let dir = repo_root.join(".chump/triage");
    std::fs::create_dir_all(&dir)?;
    let out_path = dir.join(format!("{scan_date}.md"));
    std::fs::write(&out_path, render_markdown(report, scan_date))?;

    let symlink_path = dir.join("today.md");
    let _ = std::fs::remove_file(&symlink_path);
    #[cfg(unix)]
    {
        use std::os::unix::fs::symlink;
        let _ = symlink(out_path.file_name().unwrap(), &symlink_path);
    }
    #[cfg(not(unix))]
    {
        std::fs::copy(&out_path, &symlink_path)?;
    }
    Ok(out_path)
}

/// Emit `kind=log_triage_completed` plus one `kind=log_triage_finding_high_signal`
/// per candidate finding (AC8, AC9).
pub fn emit_ambient_events(repo_root: &Path, report: &TriageReport) {
    let ambient_path = repo_root.join(".chump-locks").join("ambient.jsonl");
    if let Some(parent) = ambient_path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let mut out = match std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)
    {
        Ok(f) => f,
        Err(_) => return,
    };
    use std::io::Write;
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    let candidate_gap_count = report.findings.len() + report.low_signal_appendix.len();
    let completed = serde_json::json!({
        "ts": ts,
        "kind": "log_triage_completed",
        "source": "log_triage",
        "finding_count": report.findings.len(),
        "parse_errors": report.parse_errors,
        "candidate_gap_count": candidate_gap_count,
    });
    let _ = writeln!(out, "{}", completed);
    for f in &report.findings {
        let payload = serde_json::json!({
            "ts": ts,
            "kind": "log_triage_finding_high_signal",
            "source": "log_triage",
            "signature": f.signature,
            "occurrences": f.occurrences,
            "dedup_status": f.dedup_status,
            "suggested_title": f.suggested_title,
        });
        let _ = writeln!(out, "{}", payload);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write_ambient(dir: &Path, lines: &[String]) {
        std::fs::create_dir_all(dir.join(".chump-locks")).unwrap();
        std::fs::write(
            dir.join(".chump-locks/ambient.jsonl"),
            lines.join("\n") + "\n",
        )
        .unwrap();
    }

    fn now_ts() -> String {
        chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string()
    }

    #[test]
    fn parse_errors_are_counted_and_skipped() {
        let dir =
            std::env::temp_dir().join(format!("chump-log-triage-parse-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let ts = now_ts();
        write_ambient(
            &dir,
            &[
                format!(r#"{{"ts":"{ts}","kind":"log_triage_test_foo"}}"#),
                "not json at all".to_string(),
                format!(r#"{{"ts":"{ts}","kind":"log_triage_test_bar"}}"#),
            ],
        );
        let (events, processed, parse_errors) =
            scan_ambient(&dir, Duration::from_secs(24 * 3600)).unwrap();
        assert_eq!(processed, 2);
        assert_eq!(parse_errors, 1);
        assert_eq!(events.len(), 2);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn histogram_counts_by_kind() {
        let dir =
            std::env::temp_dir().join(format!("chump-log-triage-hist-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join(".chump-locks")).unwrap();
        let ts = now_ts();
        let mut lines = Vec::new();
        for _ in 0..3 {
            lines.push(format!(r#"{{"ts":"{ts}","kind":"log_triage_test_alpha"}}"#));
        }
        lines.push(format!(r#"{{"ts":"{ts}","kind":"log_triage_test_beta"}}"#));
        write_ambient(&dir, &lines);

        let cfg = TriageConfig {
            repo_root: dir.clone(),
            window_h: 24,
            rare_threshold: 40,
        };
        let report = run_triage(&cfg).unwrap();
        assert_eq!(report.events_processed, 4);
        let alpha = report
            .histogram_top10
            .iter()
            .find(|(k, _)| k == "log_triage_test_alpha")
            .unwrap();
        assert_eq!(alpha.1, 3);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn gap_failed_on_done_gap_is_flagged() {
        let dir =
            std::env::temp_dir().join(format!("chump-log-triage-gapfail-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join(".chump-locks")).unwrap();
        std::fs::create_dir_all(dir.join(".chump")).unwrap();

        // Seed state.db with one DONE gap via GapStore directly.
        let store = GapStore::open(&dir).unwrap();
        let gap_id = store
            .reserve("INFRA", "fixture done gap for log-triage test", "P2", "xs")
            .unwrap();
        store.ship_for_test(&gap_id).unwrap();

        let ts = now_ts();
        write_ambient(
            &dir,
            &[
                format!(r#"{{"ts":"{ts}","kind":"gap_failed","gap_id":"{gap_id}"}}"#),
                format!(r#"{{"ts":"{ts}","kind":"gap_failed","gap_id":"{gap_id}"}}"#),
            ],
        );

        let cfg = TriageConfig {
            repo_root: dir.clone(),
            window_h: 1,
            rare_threshold: 40,
        };
        let report = run_triage(&cfg).unwrap();
        assert_eq!(report.findings.len(), 1);
        assert_eq!(report.findings[0].signature, "gap_failed_on_done_gaps");
        assert_eq!(report.findings[0].occurrences, 2);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn findings_cap_at_five_with_appendix_overflow() {
        // Synthetic: force > MAX_MAIN_FINDINGS by constructing the report
        // directly rather than via the 3 real cross-refs (there are only 3).
        let findings: Vec<TriageFinding> = (0..7)
            .map(|i| TriageFinding {
                signature: format!("synthetic_{i}"),
                evidence: vec![],
                cross_ref: String::new(),
                dedup_status: "none".to_string(),
                suggested_title: format!("synthetic finding {i}"),
                suggested_ac: String::new(),
                occurrences: (7 - i) as u64,
            })
            .collect();
        let mut sorted = findings;
        sorted.sort_by_key(|f| std::cmp::Reverse(f.occurrences));
        let overflow = sorted.split_off(MAX_MAIN_FINDINGS);
        assert_eq!(sorted.len(), 5);
        assert_eq!(overflow.len(), 2);
    }

    #[test]
    fn title_similarity_matches_consolidate_scheme() {
        let sim = title_similarity(
            "gap_failed detector firing on already-done gaps",
            "gap_failed detector firing on already done gaps",
        );
        assert!(sim > 0.8, "expected high similarity, got {sim}");
        let sim2 = title_similarity(
            "completely unrelated title here",
            "another distinct topic entirely",
        );
        assert!(sim2 < 0.3, "expected low similarity, got {sim2}");
    }

    #[test]
    fn hot_conflict_file_detected_across_two_prs() {
        let dir =
            std::env::temp_dir().join(format!("chump-log-triage-hotfile-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join(".chump-locks")).unwrap();
        std::fs::create_dir_all(dir.join(".chump")).unwrap();
        let _ = GapStore::open(&dir).unwrap();

        let ts = now_ts();
        write_ambient(
            &dir,
            &[
                format!(
                    r#"{{"ts":"{ts}","kind":"dirty_pr_unresolvable","pr":"101","conflict_files":"src/main.rs,src/foo.rs"}}"#
                ),
                format!(
                    r#"{{"ts":"{ts}","kind":"dirty_pr_unresolvable","pr":"102","conflict_files":"src/main.rs"}}"#
                ),
            ],
        );

        let cfg = TriageConfig {
            repo_root: dir.clone(),
            window_h: 1,
            rare_threshold: 40,
        };
        let report = run_triage(&cfg).unwrap();
        assert_eq!(report.findings.len(), 1);
        assert!(report.findings[0].signature.contains("src/main.rs"));
        assert_eq!(report.findings[0].occurrences, 2);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
