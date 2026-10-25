//! `chump gap` command helpers (`link-pr` canonical-store guard, RESILIENT-1650).
//!
//! Ensures `chump gap link-pr` refuses to write `gap_prs` into a store whose
//! directory carries a `NONCANONICAL` or `CHUMP_STORE_ARCHIVED` marker file.

use anyhow::{bail, Result};
use std::path::{Path, PathBuf};

/// RESILIENT-1650 (Phase R R4): return the marker path if `store_dir_or_db`
/// sits in or points to a `.chump` directory carrying a `NONCANONICAL` or
/// `CHUMP_STORE_ARCHIVED` marker.
pub fn noncanonical_store_marker(store_dir_or_db: &Path) -> Option<PathBuf> {
    if store_dir_or_db.is_dir() {
        if let Some(m) =
            chump_gap_store::GapStore::store_noncanonical_marker_in_dir(store_dir_or_db)
        {
            return Some(m);
        }
        return chump_gap_store::GapStore::store_noncanonical_marker_in_dir(
            &store_dir_or_db.join(".chump"),
        );
    }
    chump_gap_store::GapStore::store_noncanonical_marker(store_dir_or_db)
}

/// RESILIENT-1650: guard + write a `gap_prs` link via `GapStore::link_pr_opts`,
/// refusing when the target store carries a `NONCANONICAL` or
/// `CHUMP_STORE_ARCHIVED` marker.
pub fn link_pr_into_store(
    repo_root: &Path,
    gap_id: &str,
    pr_number: i64,
    head_sha: &str,
    multi: bool,
    move_link: bool,
) -> Result<()> {
    if let Some(marker) = noncanonical_store_marker(repo_root) {
        bail!(
            "RESILIENT-1650: chump gap link-pr refused — target store at {} carries non-canonical marker {}",
            repo_root.display(),
            marker.display()
        );
    }
    let store = chump_gap_store::GapStore::open(repo_root)?;
    store.link_pr_opts(gap_id, pr_number, head_sha, multi, move_link)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serial_test::serial;

    #[test]
    #[serial]
    fn gap_cmd_link_pr_refuses_noncanonical_marker() {
        let prev = std::env::var("CHUMP_STATE_DB").ok();
        std::env::remove_var("CHUMP_STATE_DB");

        let tmp = tempfile::tempdir().unwrap();
        let chump_dir = tmp.path().join(".chump");
        std::fs::create_dir_all(&chump_dir).unwrap();
        let _store = chump_gap_store::GapStore::open(tmp.path()).unwrap();

        let marker = chump_dir.join("NONCANONICAL");
        std::fs::write(&marker, "non-canonical store copy\n").unwrap();

        let err = link_pr_into_store(tmp.path(), "RESILIENT-1650", 5650, "deadbeef", false, false)
            .expect_err("link_pr_into_store must refuse NONCANONICAL store");
        let msg = format!("{err:#}");
        assert!(
            msg.contains("NONCANONICAL") && msg.contains("RESILIENT-1650"),
            "expected NONCANONICAL refusal, got: {msg}"
        );

        let verify = chump_gap_store::GapStore::open(tmp.path()).unwrap();
        assert!(
            verify
                .list_prs_for_gap("RESILIENT-1650")
                .unwrap()
                .is_empty(),
            "refused link-pr must not write gap_prs into NONCANONICAL store"
        );

        if let Some(v) = prev {
            std::env::set_var("CHUMP_STATE_DB", v);
        }
    }

    #[test]
    #[serial]
    fn gap_cmd_link_pr_refuses_archived_marker_and_allows_canonical() {
        let prev = std::env::var("CHUMP_STATE_DB").ok();
        std::env::remove_var("CHUMP_STATE_DB");

        let tmp = tempfile::tempdir().unwrap();
        let chump_dir = tmp.path().join(".chump");
        std::fs::create_dir_all(&chump_dir).unwrap();
        let store = chump_gap_store::GapStore::open(tmp.path()).unwrap();

        let marker = chump_dir.join("CHUMP_STORE_ARCHIVED");
        std::fs::write(&marker, "CHUMP_STORE_ARCHIVED\n").unwrap();

        // Both the CLI helper and GapStore::link_pr_opts directly must refuse.
        assert!(
            link_pr_into_store(tmp.path(), "RESILIENT-1650", 5651, "cafebabe", false, false)
                .is_err()
        );
        assert!(store.link_pr("RESILIENT-1650", 5651, "cafebabe").is_err());

        // Removing the marker makes the store canonical again.
        std::fs::remove_file(&marker).unwrap();
        link_pr_into_store(tmp.path(), "RESILIENT-1650", 5651, "cafebabe", false, false)
            .expect("canonical store without marker accepts link-pr");
        assert_eq!(store.list_prs_for_gap("RESILIENT-1650").unwrap().len(), 1);

        if let Some(v) = prev {
            std::env::set_var("CHUMP_STATE_DB", v);
        }
    }
}
