//! `chump rules <audit|check-budget>` — Self-pruning rulebook auditor (ZERO-WASTE-125).
//!
//! Measures every rule and gate registered in `docs/observability/RULE_REGISTRY.yaml`
//! against `.chump-locks/ambient.jsonl` over a configurable time window (default `30d`),
//! computes `fires`, `catches`, `bypasses`, `false_positives`, and `estimated_cost_s`,
//! and ranks non-protected delete candidates (`catches == 0` over the window or
//! `bypass_or_fp_rate > 0.50`).
//!
//! Protected-floor rules (`protected: true`) are structurally excluded from
//! `delete_candidates` regardless of catch count.

use chrono::{DateTime, Duration, Utc};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};

/// Canonical protected-floor rule IDs that must never be proposed for auto-deletion.
pub const PROTECTED_FLOOR_IDS: &[&str] = &[
    "never-push-to-main",
    "no-secrets-in-repo",
    "proprietary-ban",
    "no-destructive-ops-without-operator",
    "t1-t4-escalation-triggers",
    "pre-push-secret-scan",
];

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DocBudgetSpec {
    pub path: String,
    pub target_lines: usize,
    pub ceiling_lines: usize,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct BudgetsConfig {
    pub claude_md: Option<DocBudgetSpec>,
    pub agents_md: Option<DocBudgetSpec>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RuleEntry {
    pub id: String,
    pub source: String,
    pub path: String,
    pub signal: String,
    #[serde(default)]
    pub bypass_signal: String,
    #[serde(default)]
    pub protected: bool,
    #[serde(default = "default_cost_per_fire_s")]
    pub estimated_cost_per_fire_s: u64,
    #[serde(default)]
    pub description: String,
}

fn default_cost_per_fire_s() -> u64 {
    15
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RuleRegistry {
    #[serde(default = "default_version")]
    pub version: u32,
    #[serde(default)]
    pub budgets: BudgetsConfig,
    #[serde(default)]
    pub rules: Vec<RuleEntry>,
}

fn default_version() -> u32 {
    1
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct RuleMetrics {
    pub id: String,
    pub source: String,
    pub path: String,
    pub signal: String,
    pub bypass_signal: String,
    pub protected: bool,
    pub fires: u64,
    pub catches: u64,
    pub bypasses: u64,
    pub false_positives: u64,
    pub bypass_or_fp_rate: f64,
    pub estimated_cost_s: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct DeleteCandidate {
    pub id: String,
    pub source: String,
    pub path: String,
    pub signal: String,
    pub fires: u64,
    pub catches: u64,
    pub bypasses: u64,
    pub false_positives: u64,
    pub bypass_or_fp_rate: f64,
    pub estimated_cost_s: u64,
    pub reason: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuditReport {
    pub window: String,
    pub window_seconds: i64,
    pub total_rules: usize,
    pub protected_rules: usize,
    pub scanned_events: usize,
    pub rules: Vec<RuleMetrics>,
    pub delete_candidates: Vec<DeleteCandidate>,
    pub unregistered_hooks: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DocBudgetStatus {
    pub path: String,
    pub current_lines: usize,
    pub target_lines: usize,
    pub ceiling_lines: usize,
    pub over_target_by: usize,
    pub within_ceiling: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BudgetCheckReport {
    pub ok: bool,
    pub claude_md: DocBudgetStatus,
    pub agents_md: DocBudgetStatus,
}

/// Parse a window string like `"30d"`, `"24h"`, `"3600s"` into a [`Duration`].
pub fn parse_window(spec: &str) -> Result<Duration, String> {
    let s = spec.trim();
    if s.is_empty() {
        return Err("empty window spec".to_string());
    }
    let (num_str, unit) = if let Some(n) = s.strip_suffix('d') {
        (n, 'd')
    } else if let Some(n) = s.strip_suffix('h') {
        (n, 'h')
    } else if let Some(n) = s.strip_suffix('m') {
        (n, 'm')
    } else if let Some(n) = s.strip_suffix('s') {
        (n, 's')
    } else {
        (s, 'd')
    };
    let val: i64 = num_str
        .trim()
        .parse()
        .map_err(|_| format!("invalid window number in '{spec}'"))?;
    if val <= 0 {
        return Err(format!("window must be positive in '{spec}'"));
    }
    match unit {
        'd' => Ok(Duration::days(val)),
        'h' => Ok(Duration::hours(val)),
        'm' => Ok(Duration::minutes(val)),
        's' => Ok(Duration::seconds(val)),
        _ => Err(format!("unsupported window unit in '{spec}'")),
    }
}

/// Load and validate `RULE_REGISTRY.yaml`, enforcing the protected-floor invariant.
pub fn load_registry(path: &Path) -> Result<RuleRegistry, String> {
    let raw = fs::read_to_string(path)
        .map_err(|e| format!("failed to read rule registry {}: {e}", path.display()))?;
    parse_registry_yaml(&raw)
}

/// Parse `RULE_REGISTRY.yaml` content and verify that all protected-floor rules are present
/// and marked `protected: true`.
pub fn parse_registry_yaml(raw: &str) -> Result<RuleRegistry, String> {
    let mut reg: RuleRegistry = serde_yaml::from_str(raw)
        .map_err(|e| format!("failed to parse RULE_REGISTRY.yaml: {e}"))?;

    // Enforce that any rule whose ID is in PROTECTED_FLOOR_IDS is always protected=true.
    let mut seen_protected_floor = HashSet::new();
    for rule in &mut reg.rules {
        if PROTECTED_FLOOR_IDS.contains(&rule.id.as_str()) {
            if !rule.protected {
                return Err(format!(
                    "protected-floor rule '{}' must have protected: true",
                    rule.id
                ));
            }
            seen_protected_floor.insert(rule.id.clone());
        }
    }
    for req in PROTECTED_FLOOR_IDS {
        if !seen_protected_floor.contains(*req) {
            return Err(format!(
                "RULE_REGISTRY.yaml missing required protected-floor rule '{req}'"
            ));
        }
    }
    Ok(reg)
}

/// Discover `scripts/git-hooks/pre-*` files on disk that do not have an entry in the registry.
pub fn find_unregistered_git_hooks(repo_root: &Path, reg: &RuleRegistry) -> Vec<String> {
    let registered_paths: HashSet<String> = reg
        .rules
        .iter()
        .map(|r| r.path.trim_start_matches("./").to_string())
        .collect();
    let hooks_dir = repo_root.join("scripts/git-hooks");
    let mut missing = Vec::new();
    let Ok(entries) = fs::read_dir(&hooks_dir) else {
        return missing;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if !path.is_file() {
            continue;
        }
        let Some(fname) = path.file_name().and_then(|s| s.to_str()) else {
            continue;
        };
        if !fname.starts_with("pre-") {
            continue;
        }
        let rel = format!("scripts/git-hooks/{fname}");
        if !registered_paths.contains(&rel) {
            missing.push(rel);
        }
    }
    missing.sort();
    missing
}

/// Audit rules in `reg` against an `ambient.jsonl` stream within `[now - window, now]`.
pub fn audit_rules_from_jsonl(
    reg: &RuleRegistry,
    ambient_jsonl: &str,
    window_label: &str,
    window: Duration,
    now: DateTime<Utc>,
    unregistered_hooks: Vec<String>,
) -> AuditReport {
    let cutoff = now - window;
    let mut events_in_window: Vec<Value> = Vec::new();

    for line in ambient_jsonl.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let Ok(val) = serde_json::from_str::<Value>(trimmed) else {
            continue;
        };
        if !val.is_object() {
            continue;
        }
        if let Some(ts_str) = val.get("ts").and_then(Value::as_str) {
            if let Ok(dt) = DateTime::parse_from_rfc3339(ts_str) {
                if dt.with_timezone(&Utc) < cutoff {
                    continue;
                }
            }
        }
        events_in_window.push(val);
    }

    #[derive(Default)]
    struct Acc {
        fires: u64,
        catches: u64,
        bypasses: u64,
        false_positives: u64,
        extra_cost_s: u64,
    }

    let mut acc_by_id: HashMap<String, Acc> = HashMap::new();
    for rule in &reg.rules {
        acc_by_id.insert(rule.id.clone(), Acc::default());
    }

    for (idx, ev) in events_in_window.iter().enumerate() {
        let kind = ev.get("kind").and_then(Value::as_str).unwrap_or("");
        let ev_rule_id = ev
            .get("rule_id")
            .or_else(|| ev.get("rule"))
            .or_else(|| ev.get("gate"))
            .and_then(Value::as_str)
            .unwrap_or("");
        let outcome = ev
            .get("outcome")
            .or_else(|| ev.get("action"))
            .or_else(|| ev.get("result"))
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_ascii_lowercase();
        let is_bypass_flag = ev.get("bypass").and_then(Value::as_bool).unwrap_or(false)
            || ev.get("bypassed").and_then(Value::as_bool).unwrap_or(false)
            || outcome == "bypass"
            || outcome == "bypassed";
        let is_fp_flag = ev
            .get("false_positive")
            .and_then(Value::as_bool)
            .unwrap_or(false)
            || outcome == "false_positive"
            || outcome == "fp"
            || outcome == "retitle";
        let is_catch_flag = ev.get("caught").and_then(Value::as_bool).unwrap_or(false)
            || ev.get("fixed").and_then(Value::as_bool).unwrap_or(false)
            || outcome == "catch"
            || outcome == "caught"
            || outcome == "fixed"
            || outcome == "blocked";
        let ev_cost_s = ev.get("cost_s").and_then(Value::as_u64).unwrap_or(0);
        let session = ev.get("session").and_then(Value::as_str).unwrap_or("");

        for rule in &reg.rules {
            let matches_id = !ev_rule_id.is_empty() && ev_rule_id == rule.id;
            let matches_signal = !rule.signal.is_empty() && kind == rule.signal;
            let matches_bypass_signal =
                !rule.bypass_signal.is_empty() && kind == rule.bypass_signal;

            if !matches_id && !matches_signal && !matches_bypass_signal {
                continue;
            }

            let Some(acc) = acc_by_id.get_mut(&rule.id) else {
                continue;
            };
            acc.extra_cost_s += ev_cost_s;

            if matches_bypass_signal || is_bypass_flag {
                acc.bypasses += 1;
                if matches_signal && !matches_bypass_signal {
                    acc.fires += 1;
                }
                continue;
            }

            // Event matched the rule's fire signal or rule_id.
            acc.fires += 1;

            if is_fp_flag {
                acc.false_positives += 1;
                continue;
            }
            if is_catch_flag {
                acc.catches += 1;
                continue;
            }
            if outcome == "ignored" || outcome == "noop" {
                continue;
            }

            // Correlate with subsequent events in the window (look ahead up to 3 events).
            let mut followed_by_bypass_or_retitle = false;
            let mut followed_by_fix = false;
            for next_ev in events_in_window.iter().skip(idx + 1).take(3) {
                let next_session = next_ev.get("session").and_then(Value::as_str).unwrap_or("");
                if !session.is_empty() && !next_session.is_empty() && next_session != session {
                    continue;
                }
                let next_kind = next_ev.get("kind").and_then(Value::as_str).unwrap_or("");
                let next_rule = next_ev
                    .get("rule_id")
                    .or_else(|| next_ev.get("rule"))
                    .and_then(Value::as_str)
                    .unwrap_or("");
                let next_outcome = next_ev
                    .get("outcome")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_ascii_lowercase();
                if (!rule.bypass_signal.is_empty() && next_kind == rule.bypass_signal)
                    || (next_rule == rule.id
                        && (next_outcome == "bypass"
                            || next_outcome == "false_positive"
                            || next_kind.contains("bypass")
                            || next_kind.contains("retitle")))
                    || next_kind.contains("bypass")
                    || next_kind.contains("retitle")
                {
                    followed_by_bypass_or_retitle = true;
                    break;
                }
                if next_kind == "commit"
                    || next_kind == "fix_applied"
                    || next_kind == "rule_catch_fixed"
                    || next_outcome == "fixed"
                    || next_outcome == "catch"
                {
                    followed_by_fix = true;
                    break;
                }
            }

            if followed_by_bypass_or_retitle {
                acc.false_positives += 1;
            } else if followed_by_fix || kind.ends_with("_blocked") || kind.ends_with("_failed") {
                acc.catches += 1;
            }
        }
    }

    let mut rules_metrics = Vec::with_capacity(reg.rules.len());
    let mut delete_candidates = Vec::new();
    let mut protected_count = 0usize;

    for rule in &reg.rules {
        let is_protected = rule.protected || PROTECTED_FLOOR_IDS.contains(&rule.id.as_str());
        if is_protected {
            protected_count += 1;
        }
        let acc = acc_by_id.get(&rule.id).expect("invariant: acc initialized");
        let denom = acc
            .fires
            .max(acc.catches + acc.bypasses + acc.false_positives);
        let bypass_or_fp_rate = if denom > 0 {
            ((acc.bypasses + acc.false_positives) as f64) / (denom as f64)
        } else {
            0.0
        };
        let estimated_cost_s = acc.extra_cost_s
            + acc.fires.saturating_mul(rule.estimated_cost_per_fire_s)
            + acc
                .bypasses
                .saturating_mul((rule.estimated_cost_per_fire_s / 2).max(5));

        let m = RuleMetrics {
            id: rule.id.clone(),
            source: rule.source.clone(),
            path: rule.path.clone(),
            signal: rule.signal.clone(),
            bypass_signal: rule.bypass_signal.clone(),
            protected: is_protected,
            fires: acc.fires,
            catches: acc.catches,
            bypasses: acc.bypasses,
            false_positives: acc.false_positives,
            bypass_or_fp_rate: (bypass_or_fp_rate * 1000.0).round() / 1000.0,
            estimated_cost_s,
        };

        // Protected rules are NEVER included in delete_candidates.
        if !is_protected && (m.catches == 0 || m.bypass_or_fp_rate > 0.50) {
            let reason = if m.catches == 0 && m.bypass_or_fp_rate > 0.50 {
                "zero_catches_and_high_bypass_or_fp_rate".to_string()
            } else if m.catches == 0 {
                "zero_catches_in_window".to_string()
            } else {
                "high_bypass_or_fp_rate".to_string()
            };
            delete_candidates.push(DeleteCandidate {
                id: m.id.clone(),
                source: m.source.clone(),
                path: m.path.clone(),
                signal: m.signal.clone(),
                fires: m.fires,
                catches: m.catches,
                bypasses: m.bypasses,
                false_positives: m.false_positives,
                bypass_or_fp_rate: m.bypass_or_fp_rate,
                estimated_cost_s: m.estimated_cost_s,
                reason,
            });
        }
        rules_metrics.push(m);
    }

    // Rank delete candidates by cost, bypasses, false_positives, fires descending.
    delete_candidates.sort_by(|a, b| {
        b.estimated_cost_s
            .cmp(&a.estimated_cost_s)
            .then_with(|| b.bypasses.cmp(&a.bypasses))
            .then_with(|| b.false_positives.cmp(&a.false_positives))
            .then_with(|| b.fires.cmp(&a.fires))
            .then_with(|| a.id.cmp(&b.id))
    });

    AuditReport {
        window: window_label.to_string(),
        window_seconds: window.num_seconds(),
        total_rules: reg.rules.len(),
        protected_rules: protected_count,
        scanned_events: events_in_window.len(),
        rules: rules_metrics,
        delete_candidates,
        unregistered_hooks,
    }
}

/// Check `CLAUDE.md` and `AGENTS.md` line counts against target and ratcheted ceiling budgets.
pub fn check_doc_budgets(
    reg: &RuleRegistry,
    claude_md_path: &Path,
    agents_md_path: &Path,
) -> Result<BudgetCheckReport, String> {
    let claude_spec = reg.budgets.claude_md.clone().unwrap_or(DocBudgetSpec {
        path: "CLAUDE.md".to_string(),
        target_lines: 150,
        ceiling_lines: 720,
    });
    let agents_spec = reg.budgets.agents_md.clone().unwrap_or(DocBudgetSpec {
        path: "AGENTS.md".to_string(),
        target_lines: 300,
        ceiling_lines: 1200,
    });

    let claude_lines = fs::read_to_string(claude_md_path)
        .map_err(|e| format!("failed to read {}: {e}", claude_md_path.display()))?
        .lines()
        .count();
    let agents_lines = fs::read_to_string(agents_md_path)
        .map_err(|e| format!("failed to read {}: {e}", agents_md_path.display()))?
        .lines()
        .count();

    let claude_status = DocBudgetStatus {
        path: claude_md_path.display().to_string(),
        current_lines: claude_lines,
        target_lines: claude_spec.target_lines,
        ceiling_lines: claude_spec.ceiling_lines,
        over_target_by: claude_lines.saturating_sub(claude_spec.target_lines),
        within_ceiling: claude_lines <= claude_spec.ceiling_lines,
    };
    let agents_status = DocBudgetStatus {
        path: agents_md_path.display().to_string(),
        current_lines: agents_lines,
        target_lines: agents_spec.target_lines,
        ceiling_lines: agents_spec.ceiling_lines,
        over_target_by: agents_lines.saturating_sub(agents_spec.target_lines),
        within_ceiling: agents_lines <= agents_spec.ceiling_lines,
    };

    Ok(BudgetCheckReport {
        ok: claude_status.within_ceiling && agents_status.within_ceiling,
        claude_md: claude_status,
        agents_md: agents_status,
    })
}

/// Entrypoint for `chump rules <audit|check-budget> ...`.
pub fn run(args: &[String]) -> i32 {
    let sub = args.first().map(String::as_str).unwrap_or("audit");
    match sub {
        "audit" => {
            let rest = if args.is_empty() { &[] } else { &args[1..] };
            run_audit(rest)
        }
        "check-budget" => run_check_budget(&args[1..]),
        "--help" | "-h" | "help" => {
            print_help();
            0
        }
        other if other.starts_with("--") => run_audit(args),
        other => {
            eprintln!(
                "chump rules: unknown subcommand '{other}' (expected 'audit' or 'check-budget')"
            );
            print_help();
            2
        }
    }
}

fn print_help() {
    println!("Usage:");
    println!("  chump rules audit [--window 30d] [--json] [--registry <path>] [--ambient <path>] [--strict-unregistered]");
    println!("  chump rules check-budget [--json] [--registry <path>] [--claude-md <path>] [--agents-md <path>]");
}

fn run_audit(args: &[String]) -> i32 {
    let repo_root = crate::repo_path::repo_root();
    let mut window_str = "30d".to_string();
    let mut json_out = false;
    let mut strict_unregistered = false;
    let mut registry_path: PathBuf = repo_root.join("docs/observability/RULE_REGISTRY.yaml");
    let mut ambient_path: PathBuf = repo_root.join(".chump-locks/ambient.jsonl");

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--window" => {
                if let Some(v) = args.get(i + 1) {
                    window_str = v.clone();
                    i += 2;
                } else {
                    eprintln!("chump rules audit: --window requires a value (e.g. 30d)");
                    return 2;
                }
            }
            "--registry" => {
                if let Some(v) = args.get(i + 1) {
                    registry_path = PathBuf::from(v);
                    i += 2;
                } else {
                    eprintln!("chump rules audit: --registry requires a path");
                    return 2;
                }
            }
            "--ambient" => {
                if let Some(v) = args.get(i + 1) {
                    ambient_path = PathBuf::from(v);
                    i += 2;
                } else {
                    eprintln!("chump rules audit: --ambient requires a path");
                    return 2;
                }
            }
            "--json" => {
                json_out = true;
                i += 1;
            }
            "--strict-unregistered" => {
                strict_unregistered = true;
                i += 1;
            }
            "--help" | "-h" => {
                print_help();
                return 0;
            }
            other => {
                eprintln!("chump rules audit: unknown argument '{other}'");
                return 2;
            }
        }
    }

    let window = match parse_window(&window_str) {
        Ok(w) => w,
        Err(e) => {
            eprintln!("chump rules audit: {e}");
            return 2;
        }
    };

    let reg = match load_registry(&registry_path) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("chump rules audit: {e}");
            return 1;
        }
    };

    let ambient_raw = fs::read_to_string(&ambient_path).unwrap_or_default();
    let unregistered_hooks = find_unregistered_git_hooks(&repo_root, &reg);
    let report = audit_rules_from_jsonl(
        &reg,
        &ambient_raw,
        &window_str,
        window,
        Utc::now(),
        unregistered_hooks,
    );

    if json_out {
        match serde_json::to_string_pretty(&report) {
            Ok(s) => println!("{s}"),
            Err(e) => {
                eprintln!("chump rules audit: failed to serialize report: {e}");
                return 1;
            }
        }
    } else {
        println!(
            "=== Chump Self-Pruning Rulebook Audit (window={}) ===",
            report.window
        );
        println!(
            "Total rules: {} (protected floor: {}) | Events scanned: {} | Delete candidates: {}",
            report.total_rules,
            report.protected_rules,
            report.scanned_events,
            report.delete_candidates.len()
        );
        println!();
        println!(
            "{:<34} {:<12} {:<9} {:>6} {:>7} {:>8} {:>4} {:>7}",
            "RULE ID", "SOURCE", "PROTECTED", "FIRES", "CATCHES", "BYPASSES", "FPS", "COST(s)"
        );
        println!("{}", "-".repeat(94));
        for r in &report.rules {
            println!(
                "{:<34} {:<12} {:<9} {:>6} {:>7} {:>8} {:>4} {:>7}",
                r.id,
                r.source,
                if r.protected { "yes" } else { "no" },
                r.fires,
                r.catches,
                r.bypasses,
                r.false_positives,
                r.estimated_cost_s
            );
        }
        if !report.delete_candidates.is_empty() {
            println!();
            println!(
                "Ranked Delete Candidates (non-protected rules with catches=0 or bypass/fp > 50%):"
            );
            for (idx, c) in report.delete_candidates.iter().enumerate() {
                println!(
                    "  {}. {} ({}) — fires={} catches={} bypasses={} fps={} rate={:.1}% cost={}s reason={}",
                    idx + 1,
                    c.id,
                    c.path,
                    c.fires,
                    c.catches,
                    c.bypasses,
                    c.false_positives,
                    c.bypass_or_fp_rate * 100.0,
                    c.estimated_cost_s,
                    c.reason
                );
            }
        }
    }

    if strict_unregistered && !report.unregistered_hooks.is_empty() {
        eprintln!(
            "chump rules audit: unregistered git hooks detected: {:?}",
            report.unregistered_hooks
        );
        return 1;
    }
    0
}

fn run_check_budget(args: &[String]) -> i32 {
    let repo_root = crate::repo_path::repo_root();
    let mut json_out = false;
    let mut registry_path: PathBuf = repo_root.join("docs/observability/RULE_REGISTRY.yaml");
    let mut claude_path: PathBuf = repo_root.join("CLAUDE.md");
    let mut agents_path: PathBuf = repo_root.join("AGENTS.md");

    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--registry" => {
                if let Some(v) = args.get(i + 1) {
                    registry_path = PathBuf::from(v);
                    i += 2;
                } else {
                    eprintln!("chump rules check-budget: --registry requires a path");
                    return 2;
                }
            }
            "--claude-md" => {
                if let Some(v) = args.get(i + 1) {
                    claude_path = PathBuf::from(v);
                    i += 2;
                } else {
                    eprintln!("chump rules check-budget: --claude-md requires a path");
                    return 2;
                }
            }
            "--agents-md" => {
                if let Some(v) = args.get(i + 1) {
                    agents_path = PathBuf::from(v);
                    i += 2;
                } else {
                    eprintln!("chump rules check-budget: --agents-md requires a path");
                    return 2;
                }
            }
            "--json" => {
                json_out = true;
                i += 1;
            }
            other => {
                eprintln!("chump rules check-budget: unknown argument '{other}'");
                return 2;
            }
        }
    }

    let reg = match load_registry(&registry_path) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("chump rules check-budget: {e}");
            return 1;
        }
    };

    let report = match check_doc_budgets(&reg, &claude_path, &agents_path) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("chump rules check-budget: {e}");
            return 1;
        }
    };

    if json_out {
        if let Ok(s) = serde_json::to_string_pretty(&report) {
            println!("{s}");
        }
    } else {
        println!(
            "CLAUDE.md: {} lines (target <= {}, ratcheted ceiling <= {}) — {}",
            report.claude_md.current_lines,
            report.claude_md.target_lines,
            report.claude_md.ceiling_lines,
            if report.claude_md.within_ceiling {
                "OK"
            } else {
                "OVER CEILING (one-in-one-out required)"
            }
        );
        println!(
            "AGENTS.md: {} lines (target <= {}, ratcheted ceiling <= {}) — {}",
            report.agents_md.current_lines,
            report.agents_md.target_lines,
            report.agents_md.ceiling_lines,
            if report.agents_md.within_ceiling {
                "OK"
            } else {
                "OVER CEILING (one-in-one-out required)"
            }
        );
    }

    if report.ok {
        0
    } else {
        1
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_registry_yaml() -> &'static str {
        r#"
version: 1
budgets:
  claude_md:
    path: CLAUDE.md
    target_lines: 150
    ceiling_lines: 720
  agents_md:
    path: AGENTS.md
    target_lines: 300
    ceiling_lines: 1200
rules:
  - id: never-push-to-main
    source: git_hook
    path: scripts/git-hooks/pre-push
    signal: pre_push_main_blocked
    protected: true
  - id: no-secrets-in-repo
    source: git_hook
    path: scripts/git-hooks/pre-commit
    signal: credential_check_failed
    protected: true
  - id: proprietary-ban
    source: git_hook
    path: scripts/git-hooks/pre-commit-private-topology-guard.sh
    signal: private_topology_blocked
    protected: true
  - id: no-destructive-ops-without-operator
    source: doc
    path: CLAUDE.md
    signal: destructive_git_blocked
    protected: true
  - id: t1-t4-escalation-triggers
    source: doc
    path: CLAUDE.md
    signal: hitl_approval_required
    protected: true
  - id: pre-push-secret-scan
    source: git_hook
    path: scripts/git-hooks/pre-push
    signal: secret_scan_blocked
    protected: true
  - id: pre-commit-rust-first
    source: git_hook
    path: scripts/git-hooks/pre-commit-rust-first.sh
    signal: rust_first_blocked
    bypass_signal: rust_first_bypass_used
    protected: false
    estimated_cost_per_fire_s: 20
  - id: pre-commit-redundancy
    source: git_hook
    path: scripts/git-hooks/pre-commit-redundancy.sh
    signal: redundancy_blocked
    bypass_signal: redundancy_bypass_used
    protected: false
    estimated_cost_per_fire_s: 20
  - id: dormant-doc-rule
    source: doc
    path: CLAUDE.md
    signal: dormant_doc_signal
    protected: false
    estimated_cost_per_fire_s: 10
"#
    }

    #[test]
    fn registry_parsing_and_protected_floor_invariant() {
        let reg = parse_registry_yaml(sample_registry_yaml()).expect("valid registry yaml");
        assert_eq!(reg.version, 1);
        assert!(reg.rules.len() >= 9);

        for floor_id in PROTECTED_FLOOR_IDS {
            let entry = reg
                .rules
                .iter()
                .find(|r| r.id == *floor_id)
                .expect("protected floor rule present");
            assert!(
                entry.protected,
                "floor rule {floor_id} must be protected: true"
            );
        }

        // Also verify the real docs/observability/RULE_REGISTRY.yaml parses cleanly.
        let repo_reg_path =
            Path::new(env!("CARGO_MANIFEST_DIR")).join("docs/observability/RULE_REGISTRY.yaml");
        let repo_reg = load_registry(&repo_reg_path).expect("repo RULE_REGISTRY.yaml parses");
        assert!(repo_reg.rules.len() >= 25);
    }

    #[test]
    fn audit_computes_fires_catches_bypasses_fps_and_delete_candidates() {
        let reg = parse_registry_yaml(sample_registry_yaml()).expect("valid registry");
        let now = DateTime::parse_from_rfc3339("2026-10-25T12:00:00Z")
            .expect("valid time")
            .with_timezone(&Utc);
        let ambient = r#"
{"ts":"2026-10-20T10:00:00Z","kind":"rust_first_blocked","session":"s1"}
{"ts":"2026-10-20T10:01:00Z","kind":"rust_first_bypass_used","session":"s1"}
{"ts":"2026-10-21T10:00:00Z","kind":"rust_first_blocked","session":"s2","outcome":"false_positive"}
{"ts":"2026-10-22T10:00:00Z","kind":"rust_first_bypass_used","session":"s3"}
{"ts":"2026-10-23T10:00:00Z","kind":"redundancy_blocked","session":"s4","outcome":"catch"}
{"ts":"2026-10-24T10:00:00Z","kind":"redundancy_blocked","session":"s5"}
{"ts":"2026-10-24T10:02:00Z","kind":"commit","session":"s5"}
"#;
        let window = parse_window("30d").expect("30d window");
        let report = audit_rules_from_jsonl(&reg, ambient, "30d", window, now, Vec::new());

        let rust_first = report
            .rules
            .iter()
            .find(|r| r.id == "pre-commit-rust-first")
            .expect("pre-commit-rust-first metrics");
        assert_eq!(rust_first.fires, 2);
        assert_eq!(rust_first.bypasses, 2);
        assert_eq!(rust_first.false_positives, 2);
        assert_eq!(rust_first.catches, 0);
        assert!(rust_first.bypass_or_fp_rate > 0.50);

        let redundancy = report
            .rules
            .iter()
            .find(|r| r.id == "pre-commit-redundancy")
            .expect("pre-commit-redundancy metrics");
        assert_eq!(redundancy.fires, 2);
        assert_eq!(redundancy.catches, 2);
        assert_eq!(redundancy.bypasses, 0);

        // pre-commit-rust-first and dormant-doc-rule should be delete candidates;
        // pre-commit-redundancy (2 catches, 0 bypasses) should NOT be.
        let cand_ids: Vec<&str> = report
            .delete_candidates
            .iter()
            .map(|c| c.id.as_str())
            .collect();
        assert!(cand_ids.contains(&"pre-commit-rust-first"));
        assert!(cand_ids.contains(&"dormant-doc-rule"));
        assert!(!cand_ids.contains(&"pre-commit-redundancy"));
        // Higher-cost/bypass rule (pre-commit-rust-first) ranks first.
        assert_eq!(report.delete_candidates[0].id, "pre-commit-rust-first");
    }

    #[test]
    fn protected_floor_rules_never_ranked_as_delete_candidates_even_with_zero_catches() {
        let reg = parse_registry_yaml(sample_registry_yaml()).expect("valid registry");
        let now = Utc::now();
        let window = parse_window("30d").expect("30d");
        let report = audit_rules_from_jsonl(&reg, "", "30d", window, now, Vec::new());

        for floor_id in PROTECTED_FLOOR_IDS {
            assert!(
                !report.delete_candidates.iter().any(|c| c.id == *floor_id),
                "protected rule {floor_id} must NEVER appear in delete_candidates"
            );
        }
    }

    #[test]
    fn one_in_one_out_budget_ratchet_check() {
        let reg = parse_registry_yaml(sample_registry_yaml()).expect("valid registry");
        let tmp =
            std::env::temp_dir().join(format!("chump-rules-budget-test-{}", std::process::id()));
        let _ = fs::create_dir_all(&tmp);
        let claude_md = tmp.join("CLAUDE.md");
        let agents_md = tmp.join("AGENTS.md");

        fs::write(&claude_md, "line\n".repeat(700)).expect("write claude");
        fs::write(&agents_md, "line\n".repeat(1150)).expect("write agents");

        let ok_report = check_doc_budgets(&reg, &claude_md, &agents_md).expect("check budgets");
        assert!(ok_report.ok);
        assert!(ok_report.claude_md.within_ceiling);
        assert!(ok_report.agents_md.within_ceiling);

        // Exceed ceiling without removing lines (violating one-in-one-out):
        fs::write(&claude_md, "line\n".repeat(750)).expect("write over-ceiling claude");
        let fail_report = check_doc_budgets(&reg, &claude_md, &agents_md).expect("check budgets");
        assert!(!fail_report.ok);
        assert!(!fail_report.claude_md.within_ceiling);

        let _ = fs::remove_dir_all(&tmp);
    }
}
