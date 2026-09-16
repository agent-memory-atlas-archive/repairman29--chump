//! CREDIBLE-1277: prune_ledger — identify low-criticality dormant ledger stages.
//!
//! CREDIBLE-1241 slice of CREDIBLE-356. A ledger is a sequence of pipeline
//! stages, each carrying a criticality score and a dormant flag (no activity
//! within the retention window). `prune_ledger` is the pure decision
//! function: given a snapshot of stages and a criticality threshold, it
//! returns the ids of stages eligible for pruning — low-criticality AND
//! dormant — without mutating anything.

/// A single stage entry in a ledger, as read by the caller before pruning.
#[derive(Debug, Clone, PartialEq)]
pub struct LedgerStage {
    pub id: String,
    pub criticality: f64,
    pub dormant: bool,
}

/// Identify low-criticality dormant stages in `stages`.
///
/// A stage is prunable when `dormant` is true AND `criticality < threshold`.
/// Pure: takes an owned snapshot, returns a new `Vec`, touches no global
/// state. Returns an empty `Vec` when no stage qualifies (including the
/// empty-input case).
pub fn prune_ledger(stages: &[LedgerStage], threshold: f64) -> Vec<String> {
    stages
        .iter()
        .filter(|stage| stage.dormant && stage.criticality < threshold)
        .map(|stage| stage.id.clone())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn stage(id: &str, criticality: f64, dormant: bool) -> LedgerStage {
        LedgerStage {
            id: id.to_string(),
            criticality,
            dormant,
        }
    }

    #[test]
    fn empty_input_returns_empty() {
        assert_eq!(prune_ledger(&[], 0.5), Vec::<String>::new());
    }

    #[test]
    fn no_low_crit_dormant_stages_returns_empty() {
        let stages = vec![
            stage("a", 0.9, true),  // high crit, dormant — not prunable
            stage("b", 0.1, false), // low crit, active — not prunable
        ];
        assert_eq!(prune_ledger(&stages, 0.5), Vec::<String>::new());
    }

    #[test]
    fn identifies_low_crit_dormant_stages() {
        let stages = vec![
            stage("a", 0.9, true),
            stage("b", 0.2, true),
            stage("c", 0.1, false),
            stage("d", 0.4, true),
        ];
        assert_eq!(prune_ledger(&stages, 0.5), vec!["b", "d"]);
    }

    #[test]
    fn is_pure_does_not_mutate_input() {
        let stages = vec![stage("a", 0.1, true)];
        let before = stages.clone();
        let _ = prune_ledger(&stages, 0.5);
        assert_eq!(stages, before);
    }
}
