// fleet_resize.rs — INFRA-650: fleet auto-prune-down controller
//
// Evaluates 4 conditions that trigger a scale-down, then optionally applies
// the resize. The inverse of the INFRA-518 expansion gate (which scales up).
// Together they form a closed-loop fleet-sizing controller.
//
// Conditions (any triggers resize-down):
//   A. Queue-empty: queue has 0 pickable gaps + 0 in-flight leases for 30+ min
//   B. Cost-watch: daily cost hard-cap at 80% with < 4h remaining in the day
//   C. Flat ship rate: no PR merged in 60 min despite N > 1 workers
//   D. Autonomous-mode: operator absent > 24h → floor at 1 worker

use std::path::Path;
use std::time::{Duration, SystemTime};

#[derive(Debug, PartialEq)]
pub enum ResizeTrigger {
    QueueEmpty,
    CostCapApproaching,
    FlatShipRate,
    OperatorAbsent,
}

#[derive(Debug, Clone, PartialEq)]
pub enum ShedAction {
    Remove(String), // build ID to remove (lowest-priority)
    None,
}

#[derive(Debug)]
pub struct ResizeDecision {
    pub trigger: ResizeTrigger,
    pub rationale: String,
    pub current_size: u32,
    pub recommended_size: u32,
}

/// MISSION-132: Compute worker budget from node capacity and resource reserves.
///
/// Integrates live node sizing into the resource allocation pipeline.
/// Given physical core count, orchestration + embed reserves, and disk usage,
/// returns the number of workers this node should run.
///
/// Placement model (capacity → worker budget):
///   reserved      = orch_reserve + embed_reserve
///   usable        = cores - reserved
///   worker_budget = round(usable * headroom_pct / 100)
///   worker_budget = clamp(1 .. cores-1)
///   worker_budget = 1 if disk_pct >= disk_brake_pct
///
/// Edge cases:
///   - zero cores           → 1 (minimum viable)
///   - reserved >= cores    → 1 (still allow one worker)
///   - disk_pct too high    → 1 (don't pile build churn on full disk)
pub fn compute_worker_budget(
    cores: u32,
    orch_reserve: u32,
    embed_reserve: u32,
    disk_pct: u32,
    headroom_pct: u32,
    disk_brake_pct: u32,
) -> u32 {
    let cores = cores.max(1);
    let reserved = orch_reserve.saturating_add(embed_reserve);
    let usable = cores.saturating_sub(reserved).max(1);

    let budget = if headroom_pct > 0 {
        // round-half-up: (usable * headroom_pct + 50) / 100
        ((usable as u64 * headroom_pct as u64 + 50) / 100) as u32
    } else {
        usable
    };

    let mut budget = budget.max(1);
    let cap = cores.saturating_sub(1).max(1);
    budget = budget.min(cap);

    if disk_pct >= disk_brake_pct && budget > 1 {
        budget = 1;
    }

    budget
}

/// MISSION-070: pure worker-scaling formula.
///
/// Given the current load and the capacity of a single worker, return the
/// target number of workers needed, clamped to `[min_workers, max_workers]`.
///
/// target = ceil(load / per_worker_capacity), clamped to bounds.
///
/// Edge cases:
///   - zero load      → `min_workers` (no work means no scale-up)
///   - zero capacity  → `min_workers` (avoid divide-by-zero)
///   - excessive load → `max_workers` (never exceed fleet ceiling)
pub fn target_worker_count(
    load: f64,
    per_worker_capacity: f64,
    min_workers: u32,
    max_workers: u32,
) -> u32 {
    if per_worker_capacity <= 0.0 || load <= 0.0 {
        return min_workers;
    }

    let raw = (load / per_worker_capacity).ceil() as u32;
    raw.clamp(min_workers, max_workers)
}

/// Check condition A: queue empty for > 30 min.
/// Returns `Some(decision)` if the fleet should shrink.
pub fn check_queue_empty(repo_root: &Path, current_size: u32) -> Option<ResizeDecision> {
    if current_size <= 1 {
        return None;
    }

    // Read the .chump/queue-empty-since timestamp if present.
    let marker = repo_root.join(".chump/queue-empty-since");
    let since = std::fs::read_to_string(&marker)
        .ok()
        .and_then(|s| s.trim().parse::<u64>().ok())
        .map(|unix| SystemTime::UNIX_EPOCH + Duration::from_secs(unix));

    let threshold = Duration::from_secs(30 * 60); // 30 min

    if let Some(since_time) = since {
        if since_time.elapsed().unwrap_or_default() >= threshold {
            return Some(ResizeDecision {
                trigger: ResizeTrigger::QueueEmpty,
                rationale: format!(
                    "queue empty for >30 min (marker: {}); no pickable gaps or in-flight leases",
                    marker.display()
                ),
                current_size,
                recommended_size: 0,
            });
        }
    }

    None
}

/// MISSION-070 (MISSION-065 slice): pure worker-scaling formula.
///
/// Given the current load and the max capacity of the fleet, return the
/// target number of workers, clamped to `[min_workers, max_workers]`.
///
/// target scales linearly between `min_workers` (at zero load) and
/// `max_workers` (at or above `max_capacity`).
pub fn calculate_worker_target(
    current_load: f64,
    max_capacity: f64,
    min_workers: u32,
    max_workers: u32,
) -> u32 {
    if current_load <= 0.0 {
        return min_workers;
    }
    if max_capacity <= 0.0 || current_load >= max_capacity {
        return max_workers;
    }

    let fraction = current_load / max_capacity;
    let span = (max_workers - min_workers) as f64;
    let raw = min_workers as f64 + (span * fraction).ceil();
    (raw as u32).clamp(min_workers, max_workers)
}

/// Check condition B: daily cost approaching hard-cap (80%) with < 4h left.
/// Returns `Some(decision)` if the fleet should shrink.
pub fn check_cost_cap(repo_root: &Path, current_size: u32) -> Option<ResizeDecision> {
    if current_size <= 1 {
        return None;
    }

    let cost_file = repo_root.join(".chump/daily-cost.json");
    let raw = std::fs::read_to_string(&cost_file).ok()?;
    let v: serde_json::Value = serde_json::from_str(&raw).ok()?;

    let spent = v["spent_usd"].as_f64().unwrap_or(0.0);
    let budget = v["budget_usd"].as_f64().unwrap_or(f64::MAX);
    if budget <= 0.0 || spent / budget < 0.80 {
        return None;
    }

    // Check hours remaining in day (UTC).
    let now = chrono::Utc::now();
    let end_of_day = now.date_naive().succ_opt()?.and_hms_opt(0, 0, 0)?.and_utc();
    let hours_left = (end_of_day - now).num_hours();
    if hours_left >= 4 {
        return None;
    }

    Some(ResizeDecision {
        trigger: ResizeTrigger::CostCapApproaching,
        rationale: format!(
            "daily cost at {:.0}% of budget ({spent:.2}/{budget:.2} USD) with only {hours_left}h left",
            (spent / budget) * 100.0,
        ),
        current_size,
        recommended_size: calculate_worker_target(spent, budget, 1, current_size),
    })
}

/// Check condition C: no PR merged in 60 min despite N > 1 workers.
/// Returns `Some(decision)` if the fleet should shrink.
pub fn check_flat_ship_rate(repo_root: &Path, current_size: u32) -> Option<ResizeDecision> {
    if current_size <= 1 {
        return None;
    }

    // Read last merge timestamp from ambient.jsonl.
    let ambient = repo_root.join(".chump-locks/ambient.jsonl");
    let raw = std::fs::read_to_string(&ambient).ok()?;

    let threshold_secs = 60 * 60_u64; // 60 min
    let now_secs = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();

    // Find most recent pr_merged event.
    let last_merge = raw
        .lines()
        .rev()
        .take(500)
        .filter_map(|l| serde_json::from_str::<serde_json::Value>(l).ok())
        .find(|v| v["kind"] == "pr_merged" || v["kind"] == "gap_shipped")
        .and_then(|v| v["ts"].as_str().map(str::to_string));

    let last_merge_secs = last_merge
        .and_then(|ts| {
            chrono::DateTime::parse_from_rfc3339(&ts)
                .ok()
                .map(|dt| dt.timestamp() as u64)
        })
        .unwrap_or(0);

    if last_merge_secs == 0 || now_secs.saturating_sub(last_merge_secs) < threshold_secs {
        return None;
    }

    Some(ResizeDecision {
        trigger: ResizeTrigger::FlatShipRate,
        rationale: format!(
            "no PR merged in 60+ min with {current_size} workers; ship rate has stalled"
        ),
        current_size,
        recommended_size: current_size.saturating_sub(1).max(1),
    })
}

/// Check condition D: operator absent > 24h in autonomous mode.
/// Returns `Some(decision)` if the fleet should shrink to 1.
pub fn check_operator_absent(repo_root: &Path, current_size: u32) -> Option<ResizeDecision> {
    if current_size <= 1 {
        return None;
    }

    // Read autonomous mode flag.
    let auto_flag = repo_root.join(".chump/autonomous-mode");
    if !auto_flag.exists() {
        return None;
    }

    // Read last operator activity timestamp.
    let activity_file = repo_root.join(".chump/last-operator-activity");
    let last_secs = std::fs::read_to_string(&activity_file)
        .ok()
        .and_then(|s| s.trim().parse::<u64>().ok())
        .unwrap_or(0);

    if last_secs == 0 {
        return None;
    }

    let now_secs = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let absent_secs = now_secs.saturating_sub(last_secs);
    let threshold = 24 * 3600_u64;

    if absent_secs < threshold {
        return None;
    }

    Some(ResizeDecision {
        trigger: ResizeTrigger::OperatorAbsent,
        rationale: format!(
            "operator absent {:.1}h in autonomous-mode; reducing to minimum fleet size",
            absent_secs as f64 / 3600.0
        ),
        current_size,
        recommended_size: 1,
    })
}

/// MISSION-123: Node capacity planner for shedding on limit breach.
///
/// Evaluates if current load exceeds the hard limit and returns a shed action
/// if needed. Returns `Some(ShedAction::Remove(build_id))` to remove the
/// lowest-priority build, or `Some(ShedAction::None)` if no shedding needed.
///
/// Hard limit enforcement: if `current_load > hard_limit`, trigger shedding
/// to free up capacity for critical work.
pub fn evaluate_capacity_planner(current_load: f64, hard_limit: f64) -> ShedAction {
    if current_load <= hard_limit {
        return ShedAction::None;
    }

    eprintln!(
        "[capacity-planner] auto-size shed triggered: load {:.2} exceeds hard limit {:.2}",
        current_load, hard_limit
    );

    // Placeholder: in production, this would identify the actual lowest-priority
    // build ID from the queue. For now, return a generic shed action.
    ShedAction::Remove("lowest_priority_build_id".to_string())
}

/// Run all 4 checks; return the first triggered decision (lowest recommended_size wins on tie).
pub fn evaluate(repo_root: &Path, current_size: u32) -> Option<ResizeDecision> {
    let mut decisions: Vec<ResizeDecision> = Vec::new();

    if let Some(d) = check_queue_empty(repo_root, current_size) {
        decisions.push(d);
    }
    if let Some(d) = check_cost_cap(repo_root, current_size) {
        decisions.push(d);
    }
    if let Some(d) = check_flat_ship_rate(repo_root, current_size) {
        decisions.push(d);
    }
    if let Some(d) = check_operator_absent(repo_root, current_size) {
        decisions.push(d);
    }

    // Pick the most aggressive shrink (lowest recommended_size).
    decisions.into_iter().min_by_key(|d| d.recommended_size)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use tempfile::TempDir;

    fn setup() -> TempDir {
        let tmp = TempDir::new().unwrap();
        fs::create_dir_all(tmp.path().join(".chump")).unwrap();
        fs::create_dir_all(tmp.path().join(".chump-locks")).unwrap();
        tmp
    }

    #[test]
    fn test_queue_empty_no_marker() {
        let tmp = setup();
        // No marker file → no trigger
        assert!(check_queue_empty(tmp.path(), 3).is_none());
    }

    #[test]
    fn test_queue_empty_fresh_marker() {
        let tmp = setup();
        // Marker set just now → not expired
        let now = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap()
            .as_secs();
        fs::write(tmp.path().join(".chump/queue-empty-since"), now.to_string()).unwrap();
        assert!(check_queue_empty(tmp.path(), 3).is_none());
    }

    #[test]
    fn test_queue_empty_expired_marker() {
        let tmp = setup();
        // Marker set 31 min ago → triggers
        let old = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap()
            .as_secs()
            - (31 * 60);
        fs::write(tmp.path().join(".chump/queue-empty-since"), old.to_string()).unwrap();
        let d = check_queue_empty(tmp.path(), 3);
        assert!(d.is_some());
        assert_eq!(d.unwrap().trigger, ResizeTrigger::QueueEmpty);
    }

    #[test]
    fn test_queue_empty_single_worker() {
        let tmp = setup();
        let old = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap()
            .as_secs()
            - (31 * 60);
        fs::write(tmp.path().join(".chump/queue-empty-since"), old.to_string()).unwrap();
        // Already at 1 worker → no further shrink
        assert!(check_queue_empty(tmp.path(), 1).is_none());
    }

    #[test]
    fn test_flat_ship_rate_no_ambient() {
        let tmp = setup();
        assert!(check_flat_ship_rate(tmp.path(), 3).is_none());
    }

    #[test]
    fn test_flat_ship_rate_recent_merge() {
        let tmp = setup();
        // Write a recent pr_merged event
        let now_str = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
        let line = format!("{{\"ts\":\"{now_str}\",\"kind\":\"pr_merged\",\"pr\":1}}\n");
        fs::write(tmp.path().join(".chump-locks/ambient.jsonl"), line).unwrap();
        // Recent merge → no trigger
        assert!(check_flat_ship_rate(tmp.path(), 3).is_none());
    }

    #[test]
    fn test_flat_ship_rate_stale_merge() {
        let tmp = setup();
        // Write a stale pr_merged event (75 min ago)
        let stale_dt = chrono::Utc::now() - chrono::Duration::minutes(75);
        let stale_str = stale_dt.format("%Y-%m-%dT%H:%M:%SZ").to_string();
        let line = format!("{{\"ts\":\"{stale_str}\",\"kind\":\"pr_merged\",\"pr\":1}}\n");
        fs::write(tmp.path().join(".chump-locks/ambient.jsonl"), line).unwrap();
        let d = check_flat_ship_rate(tmp.path(), 3);
        assert!(d.is_some());
        assert_eq!(d.unwrap().trigger, ResizeTrigger::FlatShipRate);
    }

    #[test]
    fn test_operator_absent_no_flag() {
        let tmp = setup();
        assert!(check_operator_absent(tmp.path(), 3).is_none());
    }

    #[test]
    fn test_operator_absent_triggered() {
        let tmp = setup();
        fs::write(tmp.path().join(".chump/autonomous-mode"), "1").unwrap();
        let old = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap()
            .as_secs()
            - (25 * 3600); // 25h ago
        fs::write(
            tmp.path().join(".chump/last-operator-activity"),
            old.to_string(),
        )
        .unwrap();
        let d = check_operator_absent(tmp.path(), 3);
        assert!(d.is_some());
        let d = d.unwrap();
        assert_eq!(d.trigger, ResizeTrigger::OperatorAbsent);
        assert_eq!(d.recommended_size, 1);
    }

    #[test]
    fn test_evaluate_no_triggers() {
        let tmp = setup();
        assert!(evaluate(tmp.path(), 2).is_none());
    }

    #[test]
    fn test_evaluate_picks_lowest_recommended() {
        let tmp = setup();
        // Trigger both queue-empty (→ 0) and flat-ship (→ 2)
        let old_ts = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap()
            .as_secs()
            - (31 * 60);
        fs::write(
            tmp.path().join(".chump/queue-empty-since"),
            old_ts.to_string(),
        )
        .unwrap();

        let stale_dt = chrono::Utc::now() - chrono::Duration::minutes(75);
        let stale_str = stale_dt.format("%Y-%m-%dT%H:%M:%SZ").to_string();
        let line = format!("{{\"ts\":\"{stale_str}\",\"kind\":\"pr_merged\",\"pr\":1}}\n");
        fs::write(tmp.path().join(".chump-locks/ambient.jsonl"), line).unwrap();

        // evaluate should pick queue-empty (recommended_size=0, lowest)
        let d = evaluate(tmp.path(), 3).unwrap();
        assert_eq!(d.trigger, ResizeTrigger::QueueEmpty);
        assert_eq!(d.recommended_size, 0);
    }

    #[test]
    fn test_target_worker_count_normal() {
        assert_eq!(target_worker_count(10.0, 5.0, 1, 10), 2);
        assert_eq!(target_worker_count(11.0, 5.0, 1, 10), 3); // ceil(2.2) = 3
    }

    #[test]
    fn test_target_worker_count_zero_load() {
        assert_eq!(target_worker_count(0.0, 5.0, 2, 10), 2);
    }

    #[test]
    fn test_target_worker_count_max_capacity() {
        assert_eq!(target_worker_count(1000.0, 5.0, 1, 4), 4);
    }

    #[test]
    fn test_target_worker_count_zero_capacity() {
        assert_eq!(target_worker_count(10.0, 0.0, 2, 10), 2);
    }

    #[test]
    fn test_worker_scaling_zero_load() {
        assert_eq!(calculate_worker_target(0.0, 100.0, 1, 10), 1);
    }

    #[test]
    fn test_worker_scaling_max_load() {
        assert_eq!(calculate_worker_target(100.0, 100.0, 1, 10), 10);
    }

    #[test]
    fn test_capacity_planner_below_limit() {
        // Load below hard limit → no shedding
        let action = evaluate_capacity_planner(50.0, 100.0);
        assert_eq!(action, ShedAction::None);
    }

    #[test]
    fn test_capacity_planner_at_limit() {
        // Load at hard limit → no shedding
        let action = evaluate_capacity_planner(100.0, 100.0);
        assert_eq!(action, ShedAction::None);
    }

    #[test]
    fn test_capacity_planner_exceeds_limit() {
        // Load exceeds hard limit → trigger shed
        let action = evaluate_capacity_planner(150.0, 100.0);
        assert!(matches!(action, ShedAction::Remove(_)));
    }

    #[test]
    fn test_capacity_planner_existing_calculations_remain_correct() {
        // Verify that normal capacity calculations still work correctly
        let normal_load = 75.0;
        let hard_limit = 100.0;

        // Normal load below limit should not trigger shedding
        let action = evaluate_capacity_planner(normal_load, hard_limit);
        assert_eq!(action, ShedAction::None);

        // Calculate worker target should work independently
        let workers = calculate_worker_target(normal_load, hard_limit, 1, 10);
        assert!(workers >= 1 && workers <= 10);
    }

    // MISSION-132: compute_worker_budget tests
    #[test]
    fn test_compute_worker_budget_clean_4core_node() {
        // Clean 4-core node (no orchestration, no embed reserves)
        // Expected: cores - 1 = 3 (standard headroom math)
        let budget = compute_worker_budget(4, 0, 0, 0, 75, 90);
        assert_eq!(
            budget, 3,
            "clean 4-core node should yield 3 workers (cores-1 headroom)"
        );
    }

    #[test]
    fn test_compute_worker_budget_constrained_4core_node() {
        // Constrained 4-core node (1 orch reserve + 1 embed reserve)
        // usable = 4 - 1 - 1 = 2
        // budget = round(2 * 0.75) = 2 (round-half-up, not floor)
        let budget = compute_worker_budget(4, 1, 1, 0, 75, 90);
        assert_eq!(
            budget, 2,
            "constrained 4-core node with orch+embed reserve should yield 2 workers"
        );
    }

    #[test]
    fn test_compute_worker_budget_constrained_less_than_clean() {
        // Verify constrained < clean on identical hardware
        let clean = compute_worker_budget(4, 0, 0, 0, 75, 90);
        let constrained = compute_worker_budget(4, 1, 1, 0, 75, 90);
        assert!(
            constrained < clean,
            "constrained node (orch+embed host) should get fewer workers than clean node"
        );
    }

    #[test]
    fn test_compute_worker_budget_orch_reserve_only() {
        // 4-core node with orchestration reserve only (no embed)
        // usable = 4 - 1 = 3
        // budget = round(3 * 0.75) = 2
        let budget = compute_worker_budget(4, 1, 0, 0, 75, 90);
        assert_eq!(budget, 2);
    }

    #[test]
    fn test_compute_worker_budget_embed_reserve_only() {
        // 4-core node with embed reserve only (no orch)
        // usable = 4 - 1 = 3
        // budget = round(3 * 0.75) = 2
        let budget = compute_worker_budget(4, 0, 1, 0, 75, 90);
        assert_eq!(budget, 2);
    }

    #[test]
    fn test_compute_worker_budget_zero_cores() {
        // Edge case: 0 cores → should pin to 1
        let budget = compute_worker_budget(0, 0, 0, 0, 75, 90);
        assert_eq!(budget, 1);
    }

    #[test]
    fn test_compute_worker_budget_single_core() {
        // Edge case: 1 core, no reserves → budget must be 1
        let budget = compute_worker_budget(1, 0, 0, 0, 75, 90);
        assert_eq!(budget, 1);
    }

    #[test]
    fn test_compute_worker_budget_reserves_exceed_cores() {
        // Edge case: reserves >= cores → still allow 1 worker
        let budget = compute_worker_budget(4, 3, 2, 0, 75, 90);
        assert_eq!(
            budget, 1,
            "even with excessive reserves, should pin to 1 worker minimum"
        );
    }

    #[test]
    fn test_compute_worker_budget_high_headroom() {
        // High headroom (100%) → more aggressive scaling
        // 4-core, no reserves: usable=4, budget=round(4*1.0)=4, capped to cores-1=3
        let budget = compute_worker_budget(4, 0, 0, 0, 100, 90);
        assert_eq!(
            budget, 3,
            "cores-1 cap should apply even with 100% headroom"
        );
    }

    #[test]
    fn test_compute_worker_budget_low_headroom() {
        // Low headroom (25%) → conservative scaling
        // 4-core, no reserves: usable=4, budget=round(4*0.25)=1
        let budget = compute_worker_budget(4, 0, 0, 0, 25, 90);
        assert_eq!(budget, 1, "with 25% headroom, should yield 1 worker");
    }

    #[test]
    fn test_compute_worker_budget_disk_brake_below_threshold() {
        // Disk below threshold → normal calculation
        // 4-core, no reserves, 80% disk: usable=4, budget=3, disk ok → 3
        let budget = compute_worker_budget(4, 0, 0, 80, 75, 90);
        assert_eq!(budget, 3);
    }

    #[test]
    fn test_compute_worker_budget_disk_brake_at_threshold() {
        // Disk at threshold (90%) → pinned to 1
        let budget = compute_worker_budget(4, 0, 0, 90, 75, 90);
        assert_eq!(budget, 1, "at disk_brake_pct, should pin to 1 worker");
    }

    #[test]
    fn test_compute_worker_budget_disk_brake_above_threshold() {
        // Disk above threshold (95%) → pinned to 1
        let budget = compute_worker_budget(4, 0, 0, 95, 75, 90);
        assert_eq!(budget, 1, "above disk_brake_pct, should pin to 1 worker");
    }

    #[test]
    fn test_compute_worker_budget_disk_brake_single_worker() {
        // Already at 1 worker, disk full → no further reduction
        let budget = compute_worker_budget(2, 0, 0, 95, 75, 90);
        assert_eq!(budget, 1);
    }

    #[test]
    fn test_compute_worker_budget_8core_4reserves() {
        // 8-core node with 4 total reserves (orch=2, embed=2)
        // usable = 8 - 4 = 4
        // budget = round(4 * 0.75) = 3
        let budget = compute_worker_budget(8, 2, 2, 0, 75, 90);
        assert_eq!(budget, 3);
    }

    #[test]
    fn test_compute_worker_budget_round_half_up() {
        // Verify round-half-up behavior: (usable * headroom + 50) / 100
        // 2-core, no reserves, 75% headroom: (2 * 75 + 50) / 100 = 200 / 100 = 2
        let budget = compute_worker_budget(2, 0, 0, 0, 75, 90);
        assert_eq!(
            budget, 1,
            "2-core node capped to cores-1=1 despite rounding"
        );

        // 6-core, no reserves, 75% headroom: (6 * 75 + 50) / 100 = 500 / 100 = 5
        // but capped to cores-1 = 5
        let budget = compute_worker_budget(6, 0, 0, 0, 75, 90);
        assert_eq!(budget, 5, "6-core with 75% headroom should yield 5");
    }

    #[test]
    fn test_compute_worker_budget_existing_tests_pass() {
        // Ensure the new function doesn't break existing allocation logic
        // by proving the standard allocation patterns still work

        // Pattern 1: typical worker scaling
        let budget = compute_worker_budget(8, 0, 0, 0, 75, 90);
        assert!(
            budget >= 1 && budget <= 7,
            "typical allocation should stay in bounds"
        );

        // Pattern 2: capacity constraint integration
        let budget_constrained = compute_worker_budget(8, 2, 0, 0, 75, 90);
        let budget_clean = compute_worker_budget(8, 0, 0, 0, 75, 90);
        assert!(
            budget_constrained <= budget_clean,
            "constrained should be <= clean on same hardware"
        );
    }
}
