//! INFRA-2053 — bidirectional YAML ↔ state.db reconciliation.
//!
//! Three operations:
//!   * [`sync_pull`] — YAML → DB. For each `docs/gaps/*.yaml`, parse it,
//!     compare against the corresponding state.db row, UPDATE state.db
//!     row to match YAML where they diverge. Insert NEW rows for YAML
//!     files without a DB entry. This is the RECOVERY operation for the
//!     `chump gap reserve` TODO-AC class (INFRA-2022 territory).
//!   * [`sync_push`] — DB → YAML. For every state.db row, regenerate
//!     `docs/gaps/{ID}.yaml` from the DB row. Uses
//!     [`crate::GapStore::dump_per_file_single`] which atomically writes a
//!     tempfile then renames into place; preserves the canonical schema and
//!     hand-curated unknown fields (INFRA-208).
//!   * [`sync_check`] — dry-run diff. NO mutations. Exits non-zero on any
//!     drift. Reports per-field divergence per gap id.
//!
//! Drift classes:
//!   * `DbOnly`     — state.db has a row; YAML missing (today's
//!     `gap_drift_orphan` event class; 211 instances seen at 16:57Z).
//!   * `YamlOnly`   — YAML present; state.db missing (e.g. wizard-content
//!     arrived via PR merge before state.db caught up on a fresh worktree).
//!   * `Divergent`  — both exist; one or more comparable fields differ.
//!
//! Phase 1 explicit non-goals (deferred): cron / fs-watcher auto-sync;
//! multi-machine sync (file-locking against concurrent state.db writes);
//! deleting / archiving YAMLs for `done` / `superseded` gaps; rewiring
//! callers like `chump gap reserve` to internally call `sync_pull`.
//!
//! INFRA-3606 — canonical-store split-brain fix: state.db is canonical
//! (ZERO-WASTE-020; `chump gap ship --update-yaml` is a no-op), but
//! [`sync_pull`] used to treat YAML as authoritative for every field
//! including `status`, so a gap shipped via `chump gap ship`/`gap close`
//! (state.db moves to a terminal status) got silently reverted to `open` by
//! the very next `sync --pull`, because [`sync_push`] never wrote terminal
//! statuses back out to keep the YAML mirror fresh. [`sync_pull`] now
//! refuses to pull *any* field over a state.db row already in a terminal
//! status (see `is_terminal_status`) and [`sync_push`] now mirrors every
//! status (not just open/in-progress) so the YAML side converges instead of
//! staying permanently stale.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use rusqlite::params;

use crate::{load_gap_from_yaml, parse_json_ac_list, GapRow, GapStore};

/// One per-gap drift entry produced by [`sync_check`] and by the diagnostic
/// pass that precedes [`sync_pull`] / [`sync_push`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DriftEntry {
    pub gap_id: String,
    pub kind: DriftKind,
    /// Field names that differ when `kind == Divergent`. Empty for
    /// `DbOnly` / `YamlOnly`.
    pub fields: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DriftKind {
    /// state.db has the row, but no `docs/gaps/<ID>.yaml` mirror exists.
    DbOnly,
    /// `docs/gaps/<ID>.yaml` exists, but no state.db row mirrors it.
    YamlOnly,
    /// Both exist; one or more fields differ.
    Divergent,
}

impl DriftKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            DriftKind::DbOnly => "db-only",
            DriftKind::YamlOnly => "yaml-only",
            DriftKind::Divergent => "divergent",
        }
    }
}

/// Aggregate result of [`sync_check`].
#[derive(Debug, Clone, Default)]
pub struct DriftReport {
    pub entries: Vec<DriftEntry>,
}

impl DriftReport {
    pub fn is_clean(&self) -> bool {
        self.entries.is_empty()
    }
}

/// Aggregate result of [`sync_pull`] / [`sync_push`].
#[derive(Debug, Clone, Default)]
pub struct SyncReport {
    pub inserted: usize,
    pub updated: usize,
    pub skipped: usize,
    /// INFRA-2227: count of rows where a concrete, enricher/human-authored
    /// `acceptance_criteria` in state.db was preserved instead of being
    /// clobbered by a vague/template (`TODO:`/`TBD:`/empty) YAML mirror during
    /// `sync_pull`. A non-zero value here means the anti-revert guard fired.
    pub ac_preserved: usize,
    pub changed_ids: Vec<String>,
}

// ─────────────────────────── Public API ───────────────────────────

/// Dry-run drift detection. Compares `docs/gaps/*.yaml` against
/// `state.db.gaps` and returns one [`DriftEntry`] per divergent gap id.
///
/// `gaps_dir` is the on-disk directory holding `<ID>.yaml` files (canonical
/// path: `<repo_root>/docs/gaps`).  Caller passes both the [`GapStore`] and
/// `gaps_dir` so the test fixture path can override the canonical layout.
pub fn sync_check(store: &GapStore, gaps_dir: &Path) -> Result<DriftReport> {
    let snapshot = build_snapshot(store, gaps_dir)?;
    let mut entries: Vec<DriftEntry> = Vec::new();
    for (id, pair) in &snapshot.by_id {
        match (pair.db.as_ref(), pair.yaml.as_ref()) {
            (Some(_), None) => entries.push(DriftEntry {
                gap_id: id.clone(),
                kind: DriftKind::DbOnly,
                fields: Vec::new(),
            }),
            (None, Some(_)) => entries.push(DriftEntry {
                gap_id: id.clone(),
                kind: DriftKind::YamlOnly,
                fields: Vec::new(),
            }),
            (Some(db_row), Some(yaml_row)) => {
                let diff_fields = compare_fields(db_row, yaml_row);
                if !diff_fields.is_empty() {
                    entries.push(DriftEntry {
                        gap_id: id.clone(),
                        kind: DriftKind::Divergent,
                        fields: diff_fields,
                    });
                }
            }
            (None, None) => unreachable!("snapshot.by_id keys imply at least one side present"),
        }
    }
    entries.sort_by(|a, b| a.gap_id.cmp(&b.gap_id));
    Ok(DriftReport { entries })
}

/// Reconcile YAML → DB. For each `docs/gaps/*.yaml`:
///   * If the DB has no row with that id, INSERT one with all YAML fields.
///   * If the DB row exists and any field diverges from the YAML, UPDATE
///     the row to match the YAML.
///   * If the DB row matches the YAML, no-op.
///
/// Bypasses [`GapStore::set_fields`] to avoid its integrity guards
/// (recycled-ID, title-hijack) which would refuse legitimate sync
/// operations like recovering a TODO-AC overwrite from a clean YAML.
/// Direct UPDATE statements are used instead; the YAML is treated as
/// the authoritative source of truth for this direction.
///
/// `dry_run` short-circuits all writes; the returned [`SyncReport`]
/// still enumerates which ids WOULD have been touched.
pub fn sync_pull(store: &GapStore, gaps_dir: &Path, dry_run: bool) -> Result<SyncReport> {
    let snapshot = build_snapshot(store, gaps_dir)?;
    let mut report = SyncReport::default();
    let conn = store.conn_for_sync();
    let allow_recycle = std::env::var("CHUMP_ALLOW_RECYCLE").as_deref() == Ok("1");

    for (id, pair) in &snapshot.by_id {
        let Some(yaml_row) = pair.yaml.as_ref() else {
            // YAML missing — pull is a no-op for DbOnly drift (push handles it).
            continue;
        };
        match pair.db.as_ref() {
            None => {
                // INSERT new row from YAML.
                if !dry_run {
                    insert_gap_row(conn, yaml_row)
                        .with_context(|| format!("inserting {id} from YAML during sync_pull"))?;
                }
                report.inserted += 1;
                report.changed_ids.push(id.clone());
            }
            Some(db_row) => {
                // INFRA-3606: state.db is the canonical store (ZERO-WASTE-020;
                // `chump gap ship --update-yaml` is a documented no-op). Once a
                // gap reaches a terminal status in state.db, a stale/racing
                // YAML mirror must not resurrect it. Without this guard,
                // sync_pull's raw UPDATE
                // (which deliberately bypasses `set_fields`'s recycled-ID guard)
                // reverts `chump gap ship`/`gap close` back to open on the next
                // `--pull`, which is exactly the split-brain this gap fixes.
                if is_terminal_status(&db_row.status) && !allow_recycle {
                    eprintln!(
                        "WARN: sync_pull: {id} is in terminal status '{}' — skipping YAML pull, row left unchanged (INFRA-7824)",
                        db_row.status
                    );
                    report.skipped += 1;
                    continue;
                }
                let diff_fields = compare_fields(db_row, yaml_row);
                if diff_fields.is_empty() {
                    report.skipped += 1;
                } else {
                    // INFRA-2227: anti-revert guard. The gap-enricher
                    // (EFFECTIVE-446) writes concrete acceptance_criteria to
                    // the canonical state.db but does NOT rewrite the
                    // docs/gaps/<ID>.yaml mirror. A YAML-authoritative pull
                    // would then overwrite that concrete AC with the stale
                    // `TODO:`/`TBD:` template on its very next cycle — the CJ
                    // coherence-sync loop ran this every 5 min, silently
                    // reverting every enriched gap (~100 of them). The pull's
                    // legitimate job is to reconcile *status* and other fields
                    // from the mirror; it must never downgrade a concrete spec
                    // back to boilerplate. When the YAML AC is vague but the DB
                    // AC is concrete, keep the DB AC and pull every other field.
                    let preserve_db_ac =
                        crate::acceptance_criteria_is_vague(&yaml_row.acceptance_criteria)
                            && !crate::acceptance_criteria_is_vague(&db_row.acceptance_criteria);
                    let effective_row = if preserve_db_ac {
                        let mut merged = yaml_row.clone();
                        merged.acceptance_criteria = db_row.acceptance_criteria.clone();
                        report.ac_preserved += 1;
                        merged
                    } else {
                        yaml_row.clone()
                    };
                    // Re-diff against the (possibly AC-preserved) row: if the
                    // only divergence was the AC we just protected, there is
                    // nothing left to write — skip instead of a no-op UPDATE.
                    if compare_fields(db_row, &effective_row).is_empty() {
                        report.skipped += 1;
                    } else {
                        if !dry_run {
                            update_gap_row(conn, &effective_row).with_context(|| {
                                format!("updating {id} from YAML during sync_pull")
                            })?;
                        }
                        report.updated += 1;
                        report.changed_ids.push(id.clone());
                    }
                }
            }
        }
    }
    report.changed_ids.sort();
    Ok(report)
}

/// Reconcile DB → YAML. For every state.db row, regenerate
/// `docs/gaps/{ID}.yaml` from the DB row. Uses
/// [`GapStore::dump_per_file_single`] which writes atomically (tempfile +
/// rename) and merges hand-curated unknown fields (INFRA-208).
///
/// Originally (Phase 1) this only synced OPEN + IN-PROGRESS rows, leaving
/// `done` / `superseded` YAMLs alone under the theory that their lifecycle
/// was owned by `chump gap ship --update-yaml`. That flag is now a
/// documented no-op (ZERO-WASTE-020 — state.db is canonical), which left
/// terminal-status YAMLs permanently stale with no path to reconcile them —
/// contributing to the INFRA-3606 split-brain (a stale `status: open` YAML
/// mirror looks like real drift forever). Pushing every status closes the
/// loop: state.db values flow out to the YAML mirror on the very next
/// `--push`, so `sync --check` converges to clean instead of staying dirty
/// on every shipped gap. [`sync_pull`]'s terminal-status guard (see
/// `is_terminal_status`) is what keeps this direction from being circular —
/// once a status is terminal, pull will never write it back into state.db.
pub fn sync_push(store: &GapStore, gaps_dir: &Path, dry_run: bool) -> Result<SyncReport> {
    let snapshot = build_snapshot(store, gaps_dir)?;
    let mut report = SyncReport::default();

    for (id, pair) in &snapshot.by_id {
        let Some(db_row) = pair.db.as_ref() else {
            // DB missing — push is a no-op for YamlOnly drift (pull handles it).
            continue;
        };
        let needs_write = match pair.yaml.as_ref() {
            None => true, // DbOnly drift — write the missing YAML
            Some(yaml_row) => !compare_fields(db_row, yaml_row).is_empty(),
        };
        if !needs_write {
            report.skipped += 1;
            continue;
        }
        if !dry_run {
            // dump_per_file_single does:
            //   - canonical YAML rendering via format_gap_yaml
            //   - INFRA-208 merge-preserve for hand-curated fields
            //   - byte-stable read-before-write to preserve mtime when
            //     content didn't actually change
            // It does NOT use tempfile+rename — but the read-before-write
            // check provides an equivalent atomicity property for our
            // sync use case (no partial writes on byte-stable rounds).
            // For the additional safety on first-time writes / divergent
            // updates, we write to <ID>.yaml.tmp then rename atomically.
            atomic_write_one(store, &db_row.id, gaps_dir)
                .with_context(|| format!("writing {id}.yaml during sync_push"))?;
        }
        if pair.yaml.is_none() {
            report.inserted += 1;
        } else {
            report.updated += 1;
        }
        report.changed_ids.push(id.clone());
    }
    report.changed_ids.sort();
    Ok(report)
}

// ─────────────────────────── Internal helpers ───────────────────────────

struct Pair {
    db: Option<GapRow>,
    yaml: Option<GapRow>,
}

struct Snapshot {
    by_id: BTreeMap<String, Pair>,
}

fn build_snapshot(store: &GapStore, gaps_dir: &Path) -> Result<Snapshot> {
    let mut by_id: BTreeMap<String, Pair> = BTreeMap::new();

    // DB side — list everything; downstream callers filter by status when needed.
    for row in store
        .list(None)
        .context("listing gaps from state.db for sync snapshot")?
    {
        if row.id.trim().is_empty() {
            // Defense against INFRA-112-class empty-id rows; they don't
            // map to a YAML mirror so skip them entirely.
            continue;
        }
        by_id.insert(
            row.id.clone(),
            Pair {
                db: Some(row),
                yaml: None,
            },
        );
    }

    // YAML side — walk `gaps_dir/*.yaml`. Missing-dir is OK (returns empty).
    if gaps_dir.is_dir() {
        let mut all_ids: BTreeSet<String> = by_id.keys().cloned().collect();
        // The directory walk needs a stable repo_root for load_gap_from_yaml,
        // which expects `<root>/docs/gaps/<ID>.yaml`. Recover root by going
        // up two levels from gaps_dir.
        let repo_root = synthetic_repo_root(gaps_dir);
        for entry in std::fs::read_dir(gaps_dir)
            .with_context(|| format!("reading {}", gaps_dir.display()))?
            .flatten()
        {
            let path = entry.path();
            if path.extension().and_then(|s| s.to_str()) != Some("yaml") {
                continue;
            }
            let Some(id) = path
                .file_stem()
                .and_then(|s| s.to_str())
                .map(str::to_string)
            else {
                continue;
            };
            // load_gap_from_yaml builds the path itself from repo_root + ID.
            let row_opt = load_gap_from_yaml(&repo_root, &id)
                .with_context(|| format!("loading YAML for {id}"))?;
            let Some(yaml_row) = row_opt else {
                // File exists but YAML didn't parse as a gap (empty or
                // malformed). Treat as YamlOnly with an empty row so the
                // operator notices, rather than silently dropping it.
                let entry_mut = by_id.entry(id.clone()).or_insert(Pair {
                    db: None,
                    yaml: None,
                });
                if entry_mut.yaml.is_none() {
                    entry_mut.yaml = Some(GapRow::default_empty(&id));
                }
                all_ids.insert(id);
                continue;
            };
            let entry_mut = by_id.entry(id.clone()).or_insert(Pair {
                db: None,
                yaml: None,
            });
            entry_mut.yaml = Some(yaml_row);
            all_ids.insert(id);
        }
    }

    Ok(Snapshot { by_id })
}

/// Walk up from `<root>/docs/gaps` → `<root>`. Used so we can hand
/// `load_gap_from_yaml` a repo_root that resolves the on-disk YAML path
/// correctly even when the test fixture lives outside the real repo.
fn synthetic_repo_root(gaps_dir: &Path) -> PathBuf {
    // gaps_dir == "<root>/docs/gaps" — pop twice to get "<root>".
    gaps_dir
        .parent()
        .and_then(Path::parent)
        .map(PathBuf::from)
        .unwrap_or_else(|| gaps_dir.to_path_buf())
}

/// Return the canonical list of fields that differ between two gap rows.
/// Used by both [`sync_check`] (reporting) and [`sync_pull`] / [`sync_push`]
/// (gating writes).
///
/// Fields compared (per Phase 1 hand-off contract):
///   title, status, priority, effort, acceptance_criteria, depends_on,
///   notes, description, domain, opened_date, closed_date, closed_pr,
///   skills_required, preferred_backend, preferred_machine,
///   estimated_minutes, required_model, source_doc.
///
/// `acceptance_criteria` and `depends_on` are normalised to their list-form
/// (parsed JSON) before comparison, so encoding-only differences
/// (e.g. `"[]"` vs `""`) don't register as drift.
fn compare_fields(db: &GapRow, yaml: &GapRow) -> Vec<String> {
    let mut diffs: Vec<String> = Vec::new();

    if normalize_simple(&db.title) != normalize_simple(&yaml.title) {
        diffs.push("title".into());
    }
    if normalize_simple(&db.status) != normalize_simple(&yaml.status) {
        diffs.push("status".into());
    }
    if normalize_simple(&db.priority) != normalize_simple(&yaml.priority) {
        diffs.push("priority".into());
    }
    if normalize_simple(&db.effort) != normalize_simple(&yaml.effort) {
        diffs.push("effort".into());
    }
    if normalize_list(&db.acceptance_criteria) != normalize_list(&yaml.acceptance_criteria) {
        diffs.push("acceptance_criteria".into());
    }
    if normalize_list(&db.depends_on) != normalize_list(&yaml.depends_on) {
        diffs.push("depends_on".into());
    }
    if normalize_simple(&db.notes) != normalize_simple(&yaml.notes) {
        diffs.push("notes".into());
    }
    if normalize_simple(&db.description) != normalize_simple(&yaml.description) {
        diffs.push("description".into());
    }
    if normalize_simple(&db.domain) != normalize_simple(&yaml.domain) {
        diffs.push("domain".into());
    }
    if normalize_simple(&db.opened_date) != normalize_simple(&yaml.opened_date) {
        diffs.push("opened_date".into());
    }
    if normalize_simple(&db.closed_date) != normalize_simple(&yaml.closed_date) {
        diffs.push("closed_date".into());
    }
    if db.closed_pr != yaml.closed_pr {
        diffs.push("closed_pr".into());
    }
    if normalize_simple(&db.skills_required) != normalize_simple(&yaml.skills_required) {
        diffs.push("skills_required".into());
    }
    if normalize_simple(&db.preferred_backend) != normalize_simple(&yaml.preferred_backend) {
        diffs.push("preferred_backend".into());
    }
    if normalize_simple(&db.preferred_machine) != normalize_simple(&yaml.preferred_machine) {
        diffs.push("preferred_machine".into());
    }
    if normalize_simple(&db.estimated_minutes) != normalize_simple(&yaml.estimated_minutes) {
        diffs.push("estimated_minutes".into());
    }
    if normalize_simple(&db.required_model) != normalize_simple(&yaml.required_model) {
        diffs.push("required_model".into());
    }
    if normalize_simple(&db.source_doc) != normalize_simple(&yaml.source_doc) {
        diffs.push("source_doc".into());
    }
    diffs
}

fn normalize_simple(s: &str) -> String {
    s.trim().to_string()
}

/// Normalise a JSON-stringified list (or empty string) into a sorted Vec
/// of trimmed strings.  Returns an empty Vec for both `""` and `"[]"` so
/// they compare equal — that's the encoding-vs-meaning distinction.
fn normalize_list(s: &str) -> Vec<String> {
    let mut items: Vec<String> = parse_json_ac_list(s)
        .into_iter()
        .map(|x| x.trim().to_string())
        .filter(|x| !x.is_empty())
        .collect();
    items.sort();
    items
}

/// Terminal statuses that must never be reverted by [`sync_pull`]'s
/// YAML-is-authoritative UPDATE. Mirrors the guard lists enforced elsewhere
/// in `state.db` writers: `set_fields`'s INFRA-456 recycled-ID guard (`done`)
/// and `close`'s valid-reason terminal set (`superseded`, `wontfix`, etc.).
fn is_terminal_status(status: &str) -> bool {
    matches!(
        status.trim(),
        "done"
            | "superseded"
            | "wontfix"
            | "wont_fix"
            | "closed"
            | "closed_not_a_bug"
            | "already_satisfied"
            | "obsolete"
            | "duplicate"
    )
}

/// Atomic single-gap YAML write: render via `dump_per_file_single` into a
/// sibling tempfile, validate parse, then atomically rename into place.
/// Falls back to direct `dump_per_file_single` if tempfile creation fails
/// (defense-in-depth — single-rename is already the upstream behaviour).
fn atomic_write_one(store: &GapStore, gap_id: &str, gaps_dir: &Path) -> Result<()> {
    use std::io::Write;

    let final_path = gaps_dir.join(format!("{gap_id}.yaml"));
    let tmp_path = gaps_dir.join(format!("{gap_id}.yaml.tmp"));

    // Generate canonical content into the tempfile by:
    //   1. Calling dump_per_file_single targeting a tempdir
    //   2. Reading the produced file
    //   3. Validating via serde_yaml::from_str round-trip
    //   4. fs::rename to final
    //
    // Step (1) keeps us aligned with the canonical render logic in
    // dump_per_file_single (which already merges INFRA-208 unknown fields).
    //
    // We *could* call dump_per_file_single directly against gaps_dir, but
    // that does an in-place write — for first-time YAML creation in a
    // sync_push that's still observably atomic (single rename inside fs::write).
    // For an UPDATE of an existing file we want to validate the tempfile
    // BEFORE clobbering the canonical version, so we route through a
    // tempdir + validation step.

    // Fast path for first-time creation: dump_per_file_single's fs::write
    // is already atomic on POSIX (single inode rename inside).
    if !final_path.exists() {
        store.dump_per_file_single(gap_id, gaps_dir)?;
        return Ok(());
    }

    // Update path: render to sibling tempfile, validate, then rename.
    // Use a scratch dir under gaps_dir to keep the rename on the same FS.
    let scratch_dir = gaps_dir.join(".sync-scratch");
    std::fs::create_dir_all(&scratch_dir)
        .with_context(|| format!("creating {}", scratch_dir.display()))?;
    let scratch_path = scratch_dir.join(format!("{gap_id}.yaml"));
    // Remove stale scratch from a prior crashed write, if any.
    let _ = std::fs::remove_file(&scratch_path);

    // Use dump_per_file_single targeting scratch_dir.
    store.dump_per_file_single(gap_id, &scratch_dir)?;

    // Validate the produced content round-trips as YAML.
    let produced = std::fs::read_to_string(&scratch_path)
        .with_context(|| format!("reading scratch {}", scratch_path.display()))?;
    serde_yaml::from_str::<serde_yaml::Value>(&produced)
        .with_context(|| format!("validating produced YAML for {gap_id}"))?;

    // Stage into a sibling tempfile next to the final destination
    // (same directory = atomic rename across POSIX).
    let mut tmp = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .open(&tmp_path)
        .with_context(|| format!("opening {}", tmp_path.display()))?;
    tmp.write_all(produced.as_bytes())
        .with_context(|| format!("writing {}", tmp_path.display()))?;
    tmp.sync_all().ok();
    drop(tmp);

    std::fs::rename(&tmp_path, &final_path).with_context(|| {
        format!(
            "atomic rename {} -> {}",
            tmp_path.display(),
            final_path.display()
        )
    })?;

    // Clean up scratch artifact.
    let _ = std::fs::remove_file(&scratch_path);
    let _ = std::fs::remove_dir(&scratch_dir); // succeeds only when empty

    Ok(())
}

fn insert_gap_row(conn: &rusqlite::Connection, row: &GapRow) -> Result<()> {
    let created_at = if row.created_at == 0 {
        crate::unix_now_pub()
    } else {
        row.created_at
    };
    let ac_canonical = canonicalize_list(&row.acceptance_criteria);
    let deps_canonical = canonicalize_list(&row.depends_on);
    conn.execute(
        "INSERT OR REPLACE INTO gaps(id,domain,title,description,priority,effort,status,
            acceptance_criteria,depends_on,notes,source_doc,created_at,closed_at,
            opened_date,closed_date,closed_pr,skills_required,preferred_backend,
            preferred_machine,estimated_minutes,required_model)
         VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21)",
        params![
            row.id,
            row.domain,
            row.title,
            row.description,
            row.priority,
            row.effort,
            row.status,
            ac_canonical,
            deps_canonical,
            row.notes,
            row.source_doc,
            created_at,
            row.closed_at,
            row.opened_date,
            row.closed_date,
            row.closed_pr,
            row.skills_required,
            row.preferred_backend,
            row.preferred_machine,
            row.estimated_minutes,
            row.required_model,
        ],
    )?;
    Ok(())
}

fn update_gap_row(conn: &rusqlite::Connection, row: &GapRow) -> Result<()> {
    let ac_canonical = canonicalize_list(&row.acceptance_criteria);
    let deps_canonical = canonicalize_list(&row.depends_on);
    conn.execute(
        "UPDATE gaps SET
            domain=?2, title=?3, description=?4, priority=?5, effort=?6, status=?7,
            acceptance_criteria=?8, depends_on=?9, notes=?10, source_doc=?11,
            opened_date=?12, closed_date=?13, closed_pr=?14,
            skills_required=?15, preferred_backend=?16, preferred_machine=?17,
            estimated_minutes=?18, required_model=?19
         WHERE id=?1",
        params![
            row.id,
            row.domain,
            row.title,
            row.description,
            row.priority,
            row.effort,
            row.status,
            ac_canonical,
            deps_canonical,
            row.notes,
            row.source_doc,
            row.opened_date,
            row.closed_date,
            row.closed_pr,
            row.skills_required,
            row.preferred_backend,
            row.preferred_machine,
            row.estimated_minutes,
            row.required_model,
        ],
    )?;
    Ok(())
}

/// Re-serialise an acceptance_criteria-style stored value into a canonical
/// JSON array string. Tolerates: empty input, raw JSON array, comma-joined
/// strings, and double-encoded `["[\\"a\\"]"]`. Always returns `"[]"` for
/// empty inputs so the column comparison is stable.
fn canonicalize_list(s: &str) -> String {
    let items = parse_json_ac_list(s);
    if items.is_empty() && !s.trim().is_empty() {
        // The input wasn't a JSON list but had content — preserve raw form
        // so we don't accidentally truncate hand-encoded values (e.g. a
        // pipe-joined legacy column). The DB caller will round-trip this
        // through parse_json_ac_list anyway on read.
        return s.to_string();
    }
    serde_json::to_string(&items).unwrap_or_else(|_| "[]".to_string())
}

impl GapRow {
    /// Construct an empty GapRow with the given id. Used to represent a
    /// YAML file that exists but failed to parse — caller treats it as
    /// drift rather than dropping the file silently.
    fn default_empty(id: &str) -> Self {
        GapRow {
            id: id.to_string(),
            domain: String::new(),
            title: String::new(),
            description: String::new(),
            priority: String::new(),
            effort: String::new(),
            status: String::new(),
            acceptance_criteria: String::new(),
            depends_on: String::new(),
            notes: String::new(),
            source_doc: String::new(),
            created_at: 0,
            closed_at: None,
            opened_date: String::new(),
            closed_date: String::new(),
            closed_pr: None,
            skills_required: String::new(),
            preferred_backend: String::new(),
            preferred_machine: String::new(),
            estimated_minutes: String::new(),
            required_model: String::new(),
            shipped_in: None,
            outcome_id: None,
            evidence: None,
        }
    }
}

// `GapStore::conn_for_sync` is defined alongside `conn_for_test` in lib.rs
// (pub(crate) accessor). The sync module uses it for direct INSERT/UPDATE
// without tripping the set_fields integrity guards (recycled-ID, hijack),
// which would refuse legitimate sync-pull operations like recovering a
// TODO-AC overwrite from a clean YAML.

// ─────────────────────────── Tests ───────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    fn fresh_store(repo_root: &Path) -> GapStore {
        std::env::remove_var("CHUMP_STATE_DB");
        GapStore::open(repo_root).expect("open store")
    }

    fn insert_minimal(store: &GapStore, id: &str, title: &str, ac_json: &str) {
        let conn = store.conn_for_sync();
        conn.execute(
            "INSERT INTO gaps(id,domain,title,priority,effort,status,
                acceptance_criteria,depends_on,created_at)
             VALUES(?1, 'INFRA', ?2, 'P1', 's', 'open', ?3, '[]', 1)",
            params![id, title, ac_json],
        )
        .expect("insert");
    }

    fn write_yaml(gaps_dir: &Path, id: &str, body: &str) {
        std::fs::create_dir_all(gaps_dir).expect("mkdir");
        std::fs::write(gaps_dir.join(format!("{id}.yaml")), body).expect("write");
    }

    #[test]
    fn check_reports_db_only() {
        let root = tempdir().unwrap();
        let store = fresh_store(root.path());
        insert_minimal(&store, "INFRA-9001", "Db-only gap", "[\"do thing\"]");
        let gaps_dir = root.path().join("docs/gaps");
        std::fs::create_dir_all(&gaps_dir).unwrap();
        let report = sync_check(&store, &gaps_dir).unwrap();
        assert_eq!(report.entries.len(), 1);
        assert_eq!(report.entries[0].kind, DriftKind::DbOnly);
        assert_eq!(report.entries[0].gap_id, "INFRA-9001");
    }

    #[test]
    fn check_reports_yaml_only() {
        let root = tempdir().unwrap();
        let store = fresh_store(root.path());
        let gaps_dir = root.path().join("docs/gaps");
        write_yaml(
            &gaps_dir,
            "INFRA-9002",
            "- id: INFRA-9002\n  domain: INFRA\n  title: yaml-only\n  status: open\n",
        );
        let report = sync_check(&store, &gaps_dir).unwrap();
        assert_eq!(report.entries.len(), 1);
        assert_eq!(report.entries[0].kind, DriftKind::YamlOnly);
    }

    #[test]
    fn check_reports_divergent_title() {
        let root = tempdir().unwrap();
        let store = fresh_store(root.path());
        insert_minimal(&store, "INFRA-9003", "DB title", "[]");
        let gaps_dir = root.path().join("docs/gaps");
        write_yaml(
            &gaps_dir,
            "INFRA-9003",
            "- id: INFRA-9003\n  domain: INFRA\n  title: YAML title\n  status: open\n",
        );
        let report = sync_check(&store, &gaps_dir).unwrap();
        assert_eq!(report.entries.len(), 1);
        assert_eq!(report.entries[0].kind, DriftKind::Divergent);
        assert!(report.entries[0].fields.contains(&"title".to_string()));
    }

    #[test]
    fn pull_recovers_todo_ac() {
        let root = tempdir().unwrap();
        let store = fresh_store(root.path());
        // Simulates the INFRA-2022 class: state.db has TODO ACs from
        // `chump gap reserve` boilerplate; YAML on disk has the concrete
        // ACs the operator wrote. Pull should overwrite the DB.
        insert_minimal(
            &store,
            "INFRA-9004",
            "Recover AC",
            "[\"TODO: define acceptance criteria\"]",
        );
        let gaps_dir = root.path().join("docs/gaps");
        write_yaml(
            &gaps_dir,
            "INFRA-9004",
            "- id: INFRA-9004\n  domain: INFRA\n  title: Recover AC\n  status: open\n  priority: P1\n  effort: s\n  acceptance_criteria:\n    - concrete first AC\n    - concrete second AC\n",
        );

        let report = sync_pull(&store, &gaps_dir, false).unwrap();
        assert_eq!(report.updated, 1, "expected 1 updated row");
        let after = store.get("INFRA-9004").unwrap().unwrap();
        let acs = parse_json_ac_list(&after.acceptance_criteria);
        assert_eq!(
            acs,
            vec![
                "concrete first AC".to_string(),
                "concrete second AC".to_string(),
            ]
        );

        // Re-check should be clean.
        let recheck = sync_check(&store, &gaps_dir).unwrap();
        assert!(recheck.is_clean(), "post-pull drift: {:?}", recheck.entries);
    }

    #[test]
    fn pull_preserves_concrete_db_ac_over_template_yaml() {
        // INFRA-2227: the exact incident. state.db holds the concrete AC the
        // gap-enricher wrote (db-only); the docs/gaps/<ID>.yaml mirror still
        // holds the `TODO:` observability boilerplate. A YAML-authoritative
        // pull must NOT downgrade the concrete spec back to the template.
        // This was reverting ~100 enriched gaps every 5 min via the CJ
        // coherence-sync loop.
        let root = tempdir().unwrap();
        let store = fresh_store(root.path());
        insert_minimal(
            &store,
            "INFRA-9020",
            "Enriched gap",
            "[\"scripts/ci/test-x.sh passes (3 assertions)\",\"ambient event kind=x_done registered\"]",
        );
        let gaps_dir = root.path().join("docs/gaps");
        // YAML mirror is the stale template — identical everywhere except the
        // AC, which is the TODO boilerplate.
        write_yaml(
            &gaps_dir,
            "INFRA-9020",
            "- id: INFRA-9020\n  domain: INFRA\n  title: Enriched gap\n  status: open\n  priority: P1\n  effort: s\n  acceptance_criteria:\n    - 'TODO: what events emitted on success/failure/timeout'\n    - 'TODO: smoke test command to verify observability'\n",
        );

        let report = sync_pull(&store, &gaps_dir, false).unwrap();
        assert_eq!(report.ac_preserved, 1, "guard should have fired once");
        assert_eq!(
            report.updated, 0,
            "AC was the only divergence and it was preserved — nothing to write"
        );
        let after = store.get("INFRA-9020").unwrap().unwrap();
        let acs = parse_json_ac_list(&after.acceptance_criteria);
        assert_eq!(
            acs,
            vec![
                "scripts/ci/test-x.sh passes (3 assertions)".to_string(),
                "ambient event kind=x_done registered".to_string(),
            ],
            "concrete DB acceptance_criteria was reverted to the YAML template"
        );
    }

    #[test]
    fn pull_preserves_concrete_ac_but_still_pulls_other_fields() {
        // The guard must be surgical: preserve the concrete AC AND still
        // reconcile the other fields (e.g. title) from the YAML mirror. Only
        // the AC is protected, not the whole row.
        let root = tempdir().unwrap();
        let store = fresh_store(root.path());
        insert_minimal(
            &store,
            "INFRA-9021",
            "Old DB title",
            "[\"concrete: run scripts/ci/test-y.sh and assert exit 0\"]",
        );
        let gaps_dir = root.path().join("docs/gaps");
        // YAML has a newer title but only template AC.
        write_yaml(
            &gaps_dir,
            "INFRA-9021",
            "- id: INFRA-9021\n  domain: INFRA\n  title: New YAML title\n  status: open\n  priority: P1\n  effort: s\n  acceptance_criteria:\n    - 'TBD: figure out the approach'\n",
        );

        let report = sync_pull(&store, &gaps_dir, false).unwrap();
        assert_eq!(report.ac_preserved, 1);
        assert_eq!(report.updated, 1, "title divergence should still be pulled");
        let after = store.get("INFRA-9021").unwrap().unwrap();
        assert_eq!(
            after.title, "New YAML title",
            "non-AC field should reconcile"
        );
        let acs = parse_json_ac_list(&after.acceptance_criteria);
        assert_eq!(
            acs,
            vec!["concrete: run scripts/ci/test-y.sh and assert exit 0".to_string()],
            "concrete AC must survive even when other fields are pulled"
        );
    }

    #[test]
    fn pull_does_not_revert_done_status() {
        // INFRA-3606: a gap shipped via `chump gap ship` (status=done in
        // state.db) must NOT be reverted back to open by a later
        // `gap sync --pull` just because the YAML mirror on disk is stale
        // (push never rewrites terminal-status YAMLs — see
        // `is_pushable_status`). This was the root cause of the P0
        // canonical-store split-brain: manual closes silently reverted on
        // the next pull, and re-pick loops burned cycles on already-done work.
        let root = tempdir().unwrap();
        let store = fresh_store(root.path());
        insert_minimal(&store, "INFRA-9010", "Shipped gap", "[\"do thing\"]");
        // Simulate `chump gap ship`: flip status to done directly in state.db.
        store
            .conn_for_sync()
            .execute("UPDATE gaps SET status='done' WHERE id='INFRA-9010'", [])
            .unwrap();
        // Stale YAML mirror still says open (never rewritten post-ship).
        let gaps_dir = root.path().join("docs/gaps");
        write_yaml(
            &gaps_dir,
            "INFRA-9010",
            "- id: INFRA-9010\n  domain: INFRA\n  title: Shipped gap\n  status: open\n  priority: P1\n  effort: s\n  acceptance_criteria:\n    - do thing\n",
        );

        let report = sync_pull(&store, &gaps_dir, false).unwrap();
        assert_eq!(report.updated, 0, "terminal-status row must not be pulled");
        assert_eq!(report.skipped, 1);
        let after = store.get("INFRA-9010").unwrap().unwrap();
        assert_eq!(
            after.status, "done",
            "gap sync --pull reverted a shipped gap"
        );
    }

    #[test]
    fn pull_leaves_terminal_rows_fully_untouched() {
        // INFRA-7824: sync_pull must skip any row whose status is a member
        // of `is_terminal_status`, not just `done` — and it must leave the
        // *entire* row (title, priority, acceptance_criteria, status) as-is,
        // not just refuse to flip status back to open.
        let root = tempdir().unwrap();
        let store = fresh_store(root.path());
        let gaps_dir = root.path().join("docs/gaps");

        for (gap_id, terminal_status) in [
            ("INFRA-7824-A", "superseded"),
            ("INFRA-7824-B", "wontfix"),
            ("INFRA-7824-C", "duplicate"),
        ] {
            insert_minimal(&store, gap_id, "Original title", "[\"original ac\"]");
            store
                .conn_for_sync()
                .execute(
                    &format!(
                        "UPDATE gaps SET status='{terminal_status}', priority='P3' WHERE id='{gap_id}'"
                    ),
                    [],
                )
                .unwrap();
            write_yaml(
                &gaps_dir,
                gap_id,
                &format!(
                    "- id: {gap_id}\n  domain: INFRA\n  title: Divergent YAML title\n  status: open\n  priority: P0\n  effort: s\n  acceptance_criteria:\n    - divergent ac\n"
                ),
            );
        }

        let report = sync_pull(&store, &gaps_dir, false).unwrap();
        assert_eq!(
            report.updated, 0,
            "no terminal-status row should be updated"
        );
        assert_eq!(
            report.skipped, 3,
            "all three terminal rows should be skipped"
        );

        for (gap_id, terminal_status) in [
            ("INFRA-7824-A", "superseded"),
            ("INFRA-7824-B", "wontfix"),
            ("INFRA-7824-C", "duplicate"),
        ] {
            let after = store.get(gap_id).unwrap().unwrap();
            assert_eq!(
                after.status, terminal_status,
                "{gap_id} status must not change"
            );
            assert_eq!(
                after.title, "Original title",
                "{gap_id} title must not change"
            );
            assert_eq!(after.priority, "P3", "{gap_id} priority must not change");
            let acs = parse_json_ac_list(&after.acceptance_criteria);
            assert_eq!(
                acs,
                vec!["original ac".to_string()],
                "{gap_id} acceptance_criteria must not change"
            );
        }
    }

    #[test]
    fn pull_inserts_yaml_only_gap() {
        let root = tempdir().unwrap();
        let store = fresh_store(root.path());
        let gaps_dir = root.path().join("docs/gaps");
        write_yaml(
            &gaps_dir,
            "INFRA-9005",
            "- id: INFRA-9005\n  domain: INFRA\n  title: yaml-only insert\n  status: open\n  priority: P2\n  effort: xs\n",
        );
        let report = sync_pull(&store, &gaps_dir, false).unwrap();
        assert_eq!(report.inserted, 1);
        let row = store.get("INFRA-9005").unwrap().unwrap();
        assert_eq!(row.title, "yaml-only insert");
    }

    #[test]
    fn push_creates_missing_yaml() {
        let root = tempdir().unwrap();
        let store = fresh_store(root.path());
        insert_minimal(&store, "INFRA-9006", "Push me", "[\"a\",\"b\"]");
        let gaps_dir = root.path().join("docs/gaps");
        std::fs::create_dir_all(&gaps_dir).unwrap();
        let report = sync_push(&store, &gaps_dir, false).unwrap();
        assert_eq!(report.inserted, 1);
        let path = gaps_dir.join("INFRA-9006.yaml");
        assert!(path.exists(), "expected {} to exist", path.display());
        let body = std::fs::read_to_string(&path).unwrap();
        assert!(body.contains("title: Push me"));
        assert!(body.contains("- a"));
    }

    #[test]
    fn dry_run_pull_does_not_mutate() {
        let root = tempdir().unwrap();
        let store = fresh_store(root.path());
        insert_minimal(&store, "INFRA-9007", "Stale", "[]");
        let gaps_dir = root.path().join("docs/gaps");
        write_yaml(
            &gaps_dir,
            "INFRA-9007",
            "- id: INFRA-9007\n  domain: INFRA\n  title: Updated\n  status: open\n",
        );
        let report = sync_pull(&store, &gaps_dir, true).unwrap();
        assert_eq!(report.updated, 1, "report should still count the row");
        let row = store.get("INFRA-9007").unwrap().unwrap();
        assert_eq!(row.title, "Stale", "dry-run must not mutate DB");
    }
}
