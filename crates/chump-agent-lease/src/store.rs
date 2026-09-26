//! Unified lease-storage abstraction (EFFECTIVE-1134, slice of EFFECTIVE-178 /
//! RESILIENT-103).
//!
//! [`LeaseStore`] is a small CRUD trait over a `LeaseRecord` that lets callers
//! swap the persistence back-end (SQLite, NATS-KV, or a git claim-branch)
//! without touching call sites. This sits alongside the existing
//! JSON-on-disk lease protocol in the crate root (`claim_paths` / `release` /
//! `reap_expired`) rather than replacing it — that protocol is deliberately
//! zero-dependency so external, non-Rust agents can participate by reading
//! and writing plain files. `LeaseStore` is for Rust-hosted callers that want
//! a typed, back-end-agnostic CRUD surface (e.g. a coordination daemon that
//! already talks to NATS or SQLite for other state).

use anyhow::Result;
use serde::{Deserialize, Serialize};

/// A lease record tracked by a [`LeaseStore`] back-end.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct LeaseRecord {
    /// Unique identifier for this lease (caller-assigned, e.g. a gap ID or UUID).
    pub id: String,
    /// Stable id of the session holding the lease.
    pub session_id: String,
    /// Paths covered by this lease.
    pub paths: Vec<String>,
    /// RFC3339 UTC timestamp when the lease expires unless refreshed.
    pub expires_at: String,
}

/// Back-end-agnostic CRUD over lease records.
///
/// Implementations must be safe to share across threads: callers hold a
/// `Box<dyn LeaseStore>` or `Arc<dyn LeaseStore>` behind a single
/// coordination point.
pub trait LeaseStore: Send + Sync {
    /// Insert a new lease record. Errors if `id` already exists.
    fn create(&self, record: &LeaseRecord) -> Result<()>;
    /// Look up a lease record by id. Returns `Ok(None)` if absent.
    fn read(&self, id: &str) -> Result<Option<LeaseRecord>>;
    /// Overwrite an existing lease record. Errors if `id` does not exist.
    fn update(&self, record: &LeaseRecord) -> Result<()>;
    /// Remove a lease record by id. No-op (Ok) if already absent.
    fn delete(&self, id: &str) -> Result<()>;
}

/// SQLite-backed [`LeaseStore`] — the local-dev default.
pub mod sqlite {
    use super::{LeaseRecord, LeaseStore};
    use anyhow::{anyhow, Result};
    use rusqlite::{params, Connection};
    use std::sync::Mutex;

    /// SQLite-backed lease store. Opens (and migrates) a single-table schema
    /// at construction time.
    pub struct SqliteLeaseStore {
        conn: Mutex<Connection>,
    }

    impl SqliteLeaseStore {
        /// Open (creating if absent) a SQLite-backed lease store at `path`.
        /// Pass `:memory:` for an ephemeral in-process store (tests).
        pub fn open(path: &str) -> Result<Self> {
            let conn = Connection::open(path)?;
            conn.execute(
                "CREATE TABLE IF NOT EXISTS leases (
                    id TEXT PRIMARY KEY,
                    session_id TEXT NOT NULL,
                    paths TEXT NOT NULL,
                    expires_at TEXT NOT NULL
                )",
                [],
            )?;
            Ok(Self {
                conn: Mutex::new(conn),
            })
        }

        fn row_to_record(
            id: String,
            session_id: String,
            paths_json: String,
            expires_at: String,
        ) -> Result<LeaseRecord> {
            let paths: Vec<String> = serde_json::from_str(&paths_json)?;
            Ok(LeaseRecord {
                id,
                session_id,
                paths,
                expires_at,
            })
        }
    }

    impl LeaseStore for SqliteLeaseStore {
        fn create(&self, record: &LeaseRecord) -> Result<()> {
            let conn = self.conn.lock().map_err(|_| anyhow!("lease db poisoned"))?;
            let paths_json = serde_json::to_string(&record.paths)?;
            let changed = conn.execute(
                "INSERT OR IGNORE INTO leases (id, session_id, paths, expires_at) VALUES (?1, ?2, ?3, ?4)",
                params![record.id, record.session_id, paths_json, record.expires_at],
            )?;
            if changed == 0 {
                return Err(anyhow!("lease id already exists: {}", record.id));
            }
            Ok(())
        }

        fn read(&self, id: &str) -> Result<Option<LeaseRecord>> {
            let conn = self.conn.lock().map_err(|_| anyhow!("lease db poisoned"))?;
            let mut stmt =
                conn.prepare("SELECT id, session_id, paths, expires_at FROM leases WHERE id = ?1")?;
            let mut rows = stmt.query(params![id])?;
            if let Some(row) = rows.next()? {
                let record =
                    Self::row_to_record(row.get(0)?, row.get(1)?, row.get(2)?, row.get(3)?)?;
                Ok(Some(record))
            } else {
                Ok(None)
            }
        }

        fn update(&self, record: &LeaseRecord) -> Result<()> {
            let conn = self.conn.lock().map_err(|_| anyhow!("lease db poisoned"))?;
            let paths_json = serde_json::to_string(&record.paths)?;
            let changed = conn.execute(
                "UPDATE leases SET session_id = ?2, paths = ?3, expires_at = ?4 WHERE id = ?1",
                params![record.id, record.session_id, paths_json, record.expires_at],
            )?;
            if changed == 0 {
                return Err(anyhow!("lease id does not exist: {}", record.id));
            }
            Ok(())
        }

        fn delete(&self, id: &str) -> Result<()> {
            let conn = self.conn.lock().map_err(|_| anyhow!("lease db poisoned"))?;
            conn.execute("DELETE FROM leases WHERE id = ?1", params![id])?;
            Ok(())
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        fn record(id: &str) -> LeaseRecord {
            LeaseRecord {
                id: id.to_string(),
                session_id: "session-1".to_string(),
                paths: vec!["src/foo.rs".to_string()],
                expires_at: "2026-01-01T00:00:00Z".to_string(),
            }
        }

        #[test]
        fn crud_roundtrip() {
            let store = SqliteLeaseStore::open(":memory:").unwrap();
            let rec = record("lease-1");

            store.create(&rec).unwrap();
            assert_eq!(store.read("lease-1").unwrap(), Some(rec.clone()));

            let mut updated = rec.clone();
            updated.session_id = "session-2".to_string();
            store.update(&updated).unwrap();
            assert_eq!(store.read("lease-1").unwrap(), Some(updated));

            store.delete("lease-1").unwrap();
            assert_eq!(store.read("lease-1").unwrap(), None);
        }

        #[test]
        fn create_duplicate_errors() {
            let store = SqliteLeaseStore::open(":memory:").unwrap();
            let rec = record("lease-1");
            store.create(&rec).unwrap();
            assert!(store.create(&rec).is_err());
        }

        #[test]
        fn update_missing_errors() {
            let store = SqliteLeaseStore::open(":memory:").unwrap();
            assert!(store.update(&record("missing")).is_err());
        }
    }
}

/// NATS-KV-backed [`LeaseStore`] — for fleets that already run a NATS
/// JetStream KV bucket for coordination state.
pub mod nats_kv {
    use super::{LeaseRecord, LeaseStore};
    use anyhow::{anyhow, Result};
    use async_nats::jetstream::{self, kv};
    use tokio::runtime::Handle;

    /// NATS JetStream KV-backed lease store. Each lease is one key in the bucket.
    pub struct NatsKvLeaseStore {
        store: kv::Store,
        handle: Handle,
    }

    impl NatsKvLeaseStore {
        /// Connect to `nats_url` and bind (creating if absent) the named KV bucket.
        pub async fn connect(nats_url: &str, bucket: &str) -> Result<Self> {
            let client = async_nats::connect(nats_url).await?;
            let js = jetstream::new(client);
            let store = match js.get_key_value(bucket).await {
                Ok(store) => store,
                Err(_) => {
                    js.create_key_value(kv::Config {
                        bucket: bucket.to_string(),
                        ..Default::default()
                    })
                    .await?
                }
            };
            Ok(Self {
                store,
                handle: Handle::current(),
            })
        }

        fn block_on<F: std::future::Future>(&self, fut: F) -> F::Output {
            tokio::task::block_in_place(|| self.handle.block_on(fut))
        }
    }

    impl LeaseStore for NatsKvLeaseStore {
        fn create(&self, record: &LeaseRecord) -> Result<()> {
            if self.read(&record.id)?.is_some() {
                return Err(anyhow!("lease id already exists: {}", record.id));
            }
            let payload = serde_json::to_vec(record)?;
            self.block_on(self.store.put(&record.id, payload.into()))?;
            Ok(())
        }

        fn read(&self, id: &str) -> Result<Option<LeaseRecord>> {
            let entry = self.block_on(self.store.get(id))?;
            match entry {
                Some(bytes) => Ok(Some(serde_json::from_slice(&bytes)?)),
                None => Ok(None),
            }
        }

        fn update(&self, record: &LeaseRecord) -> Result<()> {
            if self.read(&record.id)?.is_none() {
                return Err(anyhow!("lease id does not exist: {}", record.id));
            }
            let payload = serde_json::to_vec(record)?;
            self.block_on(self.store.put(&record.id, payload.into()))?;
            Ok(())
        }

        fn delete(&self, id: &str) -> Result<()> {
            self.block_on(self.store.delete(id))?;
            Ok(())
        }
    }
}

/// Git-claim-branch-backed [`LeaseStore`] — leases are represented as
/// lightweight branches (`chump-lease/<id>`) whose tip commit message carries
/// the JSON-encoded [`LeaseRecord`]. Useful when the only shared medium
/// between agents is the git remote itself (no SQLite file, no NATS broker).
pub mod git_claim_branch {
    use super::{LeaseRecord, LeaseStore};
    use anyhow::{anyhow, Context, Result};
    use std::path::{Path, PathBuf};
    use std::process::Command;

    const BRANCH_PREFIX: &str = "chump-lease/";

    /// Git-claim-branch lease store, scoped to a single local repo checkout.
    pub struct GitClaimBranchLeaseStore {
        repo_dir: PathBuf,
    }

    impl GitClaimBranchLeaseStore {
        /// Bind to the git repo rooted at `repo_dir` (must already be a git
        /// worktree; branches are created/updated/deleted locally only —
        /// pushing/fetching the claim branches is the caller's concern).
        pub fn open(repo_dir: impl AsRef<Path>) -> Self {
            Self {
                repo_dir: repo_dir.as_ref().to_path_buf(),
            }
        }

        fn branch_name(id: &str) -> String {
            format!("{BRANCH_PREFIX}{id}")
        }

        fn git(&self, args: &[&str]) -> Result<std::process::Output> {
            Command::new("git")
                .arg("-C")
                .arg(&self.repo_dir)
                .args(args)
                .output()
                .context("failed to spawn git")
        }

        fn branch_exists(&self, branch: &str) -> Result<bool> {
            let out = self.git(&["rev-parse", "--verify", "--quiet", branch])?;
            Ok(out.status.success())
        }

        fn read_commit_message(&self, branch: &str) -> Result<Option<String>> {
            if !self.branch_exists(branch)? {
                return Ok(None);
            }
            let out = self.git(&["log", "-1", "--format=%B", branch])?;
            if !out.status.success() {
                return Ok(None);
            }
            Ok(Some(
                String::from_utf8_lossy(&out.stdout).trim().to_string(),
            ))
        }

        fn write_commit(&self, record: &LeaseRecord) -> Result<()> {
            let payload = serde_json::to_string(record)?;
            // An empty, orphan-ish commit whose message carries the record —
            // no working-tree changes needed since the branch is only a
            // claim marker, not a code change.
            let out = self.git(&["commit", "--allow-empty", "--no-verify", "-m", &payload])?;
            if !out.status.success() {
                return Err(anyhow!(
                    "git commit failed: {}",
                    String::from_utf8_lossy(&out.stderr)
                ));
            }
            Ok(())
        }

        fn checkout_branch(&self, branch: &str, create: bool) -> Result<()> {
            let mut args = vec!["checkout"];
            if create {
                args.push("-b");
            }
            args.push(branch);
            let out = self.git(&args)?;
            if !out.status.success() {
                return Err(anyhow!(
                    "git checkout failed: {}",
                    String::from_utf8_lossy(&out.stderr)
                ));
            }
            Ok(())
        }

        fn current_branch(&self) -> Result<String> {
            let out = self.git(&["rev-parse", "--abbrev-ref", "HEAD"])?;
            Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
        }
    }

    impl LeaseStore for GitClaimBranchLeaseStore {
        fn create(&self, record: &LeaseRecord) -> Result<()> {
            let branch = Self::branch_name(&record.id);
            if self.branch_exists(&branch)? {
                return Err(anyhow!("lease id already exists: {}", record.id));
            }
            let original = self.current_branch()?;
            self.checkout_branch(&branch, true)?;
            let result = self.write_commit(record);
            self.checkout_branch(&original, false)?;
            result
        }

        fn read(&self, id: &str) -> Result<Option<LeaseRecord>> {
            let branch = Self::branch_name(id);
            match self.read_commit_message(&branch)? {
                Some(msg) => Ok(Some(serde_json::from_str(&msg)?)),
                None => Ok(None),
            }
        }

        fn update(&self, record: &LeaseRecord) -> Result<()> {
            let branch = Self::branch_name(&record.id);
            if !self.branch_exists(&branch)? {
                return Err(anyhow!("lease id does not exist: {}", record.id));
            }
            let original = self.current_branch()?;
            self.checkout_branch(&branch, false)?;
            let result = self.write_commit(record);
            self.checkout_branch(&original, false)?;
            result
        }

        fn delete(&self, id: &str) -> Result<()> {
            let branch = Self::branch_name(id);
            if !self.branch_exists(&branch)? {
                return Ok(());
            }
            let out = self.git(&["branch", "-D", &branch])?;
            if !out.status.success() {
                return Err(anyhow!(
                    "git branch -D failed: {}",
                    String::from_utf8_lossy(&out.stderr)
                ));
            }
            Ok(())
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use std::process::Command;
        use tempfile::TempDir;

        fn init_repo() -> TempDir {
            let dir = TempDir::new().unwrap();
            let run = |args: &[&str]| {
                let status = Command::new("git")
                    .arg("-C")
                    .arg(dir.path())
                    .args(args)
                    .status()
                    .unwrap();
                assert!(status.success());
            };
            run(&["init", "-q"]);
            run(&["config", "user.email", "test@example.com"]);
            run(&["config", "user.name", "Test"]);
            run(&["commit", "--allow-empty", "-q", "-m", "init"]);
            dir
        }

        fn record(id: &str) -> LeaseRecord {
            LeaseRecord {
                id: id.to_string(),
                session_id: "session-1".to_string(),
                paths: vec!["src/foo.rs".to_string()],
                expires_at: "2026-01-01T00:00:00Z".to_string(),
            }
        }

        #[test]
        fn crud_roundtrip() {
            let dir = init_repo();
            let store = GitClaimBranchLeaseStore::open(dir.path());
            let rec = record("lease-1");

            store.create(&rec).unwrap();
            assert_eq!(store.read("lease-1").unwrap(), Some(rec.clone()));

            let mut updated = rec.clone();
            updated.session_id = "session-2".to_string();
            store.update(&updated).unwrap();
            assert_eq!(store.read("lease-1").unwrap(), Some(updated));

            store.delete("lease-1").unwrap();
            assert_eq!(store.read("lease-1").unwrap(), None);
        }
    }
}
