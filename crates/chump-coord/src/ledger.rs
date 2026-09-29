// crates/chump-coord/src/ledger.rs — CREDIBLE-1049
//
// CREDIBLE-356 slice: deterministic `prune_ledger` computation, exposed via
// the "prune_ledger" RPC method registered in `rpc::register_worker_rpc_handlers`.
//
// Pure decision function: given a snapshot of ledger entries and a
// criticality threshold, returns the ids of entries eligible for pruning —
// low-criticality AND dormant — in deterministic order (stage id, then
// timestamp). Touches no global state.

use serde::{Deserialize, Serialize};

/// Identifier of a ledger entry.
pub type LedgerEntryId = String;

/// A single entry in a ledger, as read by the caller before pruning.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LedgerEntry {
    pub id: LedgerEntryId,
    pub criticality: f64,
    pub dormant: bool,
    /// Unix-epoch seconds. Used only as the deterministic tiebreak when two
    /// entries share the same id-sort position (never in practice, since
    /// ids are unique, but kept for AC-2's "by stage id then timestamp"
    /// ordering requirement).
    pub timestamp: i64,
}

/// Identify low-criticality dormant entries in `entries`, sorted
/// deterministically by `id` then `timestamp`.
///
/// An entry is prunable when `dormant` is true AND `criticality < threshold`.
pub fn prune_ledger(entries: &[LedgerEntry], threshold: f64) -> Vec<LedgerEntryId> {
    let mut prunable: Vec<&LedgerEntry> = entries
        .iter()
        .filter(|entry| entry.dormant && entry.criticality < threshold)
        .collect();
    prunable.sort_by(|a, b| a.id.cmp(&b.id).then(a.timestamp.cmp(&b.timestamp)));
    prunable.into_iter().map(|entry| entry.id.clone()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(id: &str, criticality: f64, dormant: bool, timestamp: i64) -> LedgerEntry {
        LedgerEntry {
            id: id.to_string(),
            criticality,
            dormant,
            timestamp,
        }
    }

    #[test]
    fn empty_input_returns_empty() {
        assert_eq!(prune_ledger(&[], 0.5), Vec::<LedgerEntryId>::new());
    }

    #[test]
    fn no_low_crit_dormant_entries_returns_empty() {
        let entries = vec![entry("a", 0.9, true, 1), entry("b", 0.1, false, 2)];
        assert_eq!(prune_ledger(&entries, 0.5), Vec::<LedgerEntryId>::new());
    }

    #[test]
    fn identifies_low_crit_dormant_entries_sorted_by_id() {
        let entries = vec![
            entry("d", 0.4, true, 4),
            entry("a", 0.9, true, 1),
            entry("b", 0.2, true, 2),
            entry("c", 0.1, false, 3),
        ];
        assert_eq!(prune_ledger(&entries, 0.5), vec!["b", "d"]);
    }

    #[test]
    fn is_pure_does_not_mutate_input() {
        let entries = vec![entry("a", 0.1, true, 1)];
        let before = entries.clone();
        let _ = prune_ledger(&entries, 0.5);
        assert_eq!(entries, before);
    }
}
