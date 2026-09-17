//! CREDIBLE-1307: prune_ledger — remove low-Crit dormant entries (CREDIBLE-356 slice).
//!
//! Sibling of `prune_ledger::prune_ledger` (CREDIBLE-1277), which only
//! *identifies* prunable stage ids without mutating anything. This slice
//! performs the actual removal: given an owned ledger of entries, it
//! returns the pruned ledger (entries that survive) plus a count of how
//! many entries were removed.

/// A single entry in a ledger, as read by the caller before pruning.
#[derive(Debug, Clone, PartialEq)]
pub struct LedgerEntry {
    pub id: String,
    pub criticality: f64,
    pub dormant: bool,
}

/// Remove low-criticality dormant entries from `ledger`.
///
/// An entry is removed when `dormant` is true AND `criticality < threshold`.
/// Returns the pruned ledger (surviving entries, order preserved) and the
/// count of entries removed.
pub fn prune_ledger(ledger: Vec<LedgerEntry>, threshold: f64) -> (Vec<LedgerEntry>, usize) {
    let before = ledger.len();
    let kept: Vec<LedgerEntry> = ledger
        .into_iter()
        .filter(|entry| !(entry.dormant && entry.criticality < threshold))
        .collect();
    let removed = before - kept.len();
    (kept, removed)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(id: &str, criticality: f64, dormant: bool) -> LedgerEntry {
        LedgerEntry {
            id: id.to_string(),
            criticality,
            dormant,
        }
    }

    #[test]
    fn empty_ledger_returns_empty_and_zero() {
        let (pruned, removed) = prune_ledger(vec![], 0.5);
        assert_eq!(pruned, Vec::<LedgerEntry>::new());
        assert_eq!(removed, 0);
    }

    #[test]
    fn removes_low_crit_dormant_entries_keeps_others() {
        let ledger = vec![
            entry("a", 0.9, true),  // high crit, dormant — kept
            entry("b", 0.2, true),  // low crit, dormant — removed
            entry("c", 0.1, false), // low crit, active — kept
            entry("d", 0.4, true),  // low crit, dormant — removed
        ];
        let (pruned, removed) = prune_ledger(ledger, 0.5);
        assert_eq!(pruned, vec![entry("a", 0.9, true), entry("c", 0.1, false)]);
        assert_eq!(removed, 2);
    }

    #[test]
    fn no_prunable_entries_leaves_ledger_unchanged() {
        let ledger = vec![entry("a", 0.9, true), entry("b", 0.1, false)];
        let (pruned, removed) = prune_ledger(ledger.clone(), 0.5);
        assert_eq!(pruned, ledger);
        assert_eq!(removed, 0);
    }
}
