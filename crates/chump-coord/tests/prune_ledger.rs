// crates/chump-coord/tests/prune_ledger.rs — CREDIBLE-1049
//
// Verifies `ledger::prune_ledger` yields the expected deterministic list of
// low-Crit dormant entries from a ledger seeded with mixed criticalities.

use chump_coord::ledger::{prune_ledger, LedgerEntry};

fn entry(id: &str, criticality: f64, dormant: bool, timestamp: i64) -> LedgerEntry {
    LedgerEntry {
        id: id.to_string(),
        criticality,
        dormant,
        timestamp,
    }
}

#[test]
fn prunes_low_crit_dormant_entries_in_deterministic_order() {
    let ledger = vec![
        entry("stage-d", 0.4, true, 400),
        entry("stage-a", 0.9, true, 100), // high crit, dormant — not prunable
        entry("stage-b", 0.2, true, 200),
        entry("stage-c", 0.1, false, 300), // low crit, active — not prunable
    ];

    let pruned = prune_ledger(&ledger, 0.5);

    assert_eq!(pruned, vec!["stage-b".to_string(), "stage-d".to_string()]);
}

#[test]
fn empty_ledger_yields_empty_result() {
    assert_eq!(prune_ledger(&[], 0.5), Vec::<String>::new());
}
