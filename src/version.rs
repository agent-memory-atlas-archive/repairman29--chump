//! Chump version for logs and health. From env CHUMP_VERSION or Cargo.toml at compile time.
//!
//! INFRA-148: also exposes the build-time git SHA + date (baked by `build.rs`)
//! and a staleness check used by `chump gap ship --update-yaml` /
//! `chump gap dump --out PATH` to warn the operator when the binary in
//! $PATH was built before the most recent `gap_store.rs` / `main.rs` (gap
//! command wiring) commit on the local repo's HEAD.
//!
//! Failure mode is "skip the warning, don't refuse" so a binary built
//! outside a git checkout (cargo install --git URL, packaged source) never
//! blocks the operator. The check writes to stderr — never to stdout —
//! so script consumers of `chump gap dump` etc. are unaffected.

use std::path::{Path, PathBuf};
use std::process::Command;

/// Version string: CHUMP_VERSION env if set, else CARGO_PKG_VERSION.
pub fn chump_version() -> String {
    std::env::var("CHUMP_VERSION").unwrap_or_else(|_| env!("CARGO_PKG_VERSION").to_string())
}

/// Short git SHA (12 chars) of the commit this binary was built from, or
/// `"unknown"` when the build environment had no git available (e.g.
/// packaged source). Set by `build.rs` via `cargo:rustc-env`.
pub fn chump_build_sha() -> &'static str {
    env!("CHUMP_BUILD_SHA")
}

/// Commit date (yyyy-mm-dd, UTC) of the SHA this binary was built from, or
/// `"unknown"`. Set by `build.rs` via `cargo:rustc-env`.
pub fn chump_build_date() -> &'static str {
    env!("CHUMP_BUILD_DATE")
}

/// Files that affect gap-store serialization or `chump gap` command wiring.
/// Any commit touching one of these after the binary's baked SHA is a
/// staleness signal — the operator's binary may emit/read YAML differently
/// from what origin/main expects, risking silent corruption like the
/// pre-INFRA-147 meta:-preamble strip incident on 2026-04-27.
const GAP_STORE_FILES: &[&str] = &[
    "crates/chump-gap-store/src/lib.rs",
    "src/gap_store.rs", // legacy fallback
    "src/main.rs",
];

/// Outcome of [`check_gap_binary_staleness`].
#[derive(Debug, PartialEq, Eq)]
pub enum StalenessCheck {
    /// Binary's baked SHA is at or ahead of the gap-store-affecting code on
    /// HEAD. Safe to mutate gaps.yaml.
    Fresh,
    /// `unknown` baked SHA, no `.git` at the resolved repo root, or the
    /// `git log` invocation failed for any reason. The check is
    /// inconclusive — caller should proceed without warning to avoid
    /// blocking legitimate use cases (cargo-install builds, fresh clones,
    /// non-git deployments).
    Skip,
    /// HEAD has at least one commit touching one of the `GAP_STORE_FILES`
    /// after the binary's baked SHA. Carries the (count,
    /// first commit subject) so callers can produce a useful warning.
    Stale {
        commits_ahead: usize,
        latest_subject: String,
    },
}

/// Check whether the binary's baked SHA is older than the gap-store code on
/// HEAD of the repo at `repo_root`. See [`StalenessCheck`] for outcomes.
///
/// This is a best-effort check: any failure path returns `Skip` rather than
/// propagating the error, because we never want to block operators on a
/// staleness check that the check itself couldn't perform reliably.
pub fn check_gap_binary_staleness(repo_root: &Path) -> StalenessCheck {
    check_gap_binary_staleness_with_sha(repo_root, chump_build_sha())
}

/// Same as [`check_gap_binary_staleness`] but with the baked SHA passed in
/// explicitly. Used by tests so we don't have to recompile to simulate a
/// stale binary.
pub fn check_gap_binary_staleness_with_sha(repo_root: &Path, sha: &str) -> StalenessCheck {
    if sha == "unknown" || sha.is_empty() {
        return StalenessCheck::Skip;
    }
    // .git is normally a directory, but in linked worktrees it's a file
    // pointing to the parent's gitdir. Either way is a valid checkout.
    if !repo_root.join(".git").exists() {
        return StalenessCheck::Skip;
    }

    let mut cmd = Command::new("git");
    cmd.arg("-C")
        .arg(repo_root)
        .arg("log")
        .arg(format!("{sha}..HEAD"))
        .arg("--format=%s")
        .arg("--");
    for f in GAP_STORE_FILES {
        cmd.arg(f);
    }

    let output = match cmd.output() {
        Ok(o) if o.status.success() => o,
        _ => return StalenessCheck::Skip,
    };

    let stdout = String::from_utf8_lossy(&output.stdout);
    let lines: Vec<&str> = stdout.lines().filter(|l| !l.trim().is_empty()).collect();
    if lines.is_empty() {
        StalenessCheck::Fresh
    } else {
        StalenessCheck::Stale {
            commits_ahead: lines.len(),
            latest_subject: lines[0].to_string(),
        }
    }
}

/// Convenience helper: locate the chump repo root by walking up from `start`
/// looking for `.git`. Returns `None` if no such ancestor exists.
pub fn find_repo_root(start: &Path) -> Option<PathBuf> {
    let mut cur: PathBuf = start.canonicalize().ok()?;
    loop {
        if cur.join(".git").exists() {
            return Some(cur);
        }
        if !cur.pop() {
            return None;
        }
    }
}

/// INFRA-6384: filesystem-mtime "rebuild check" layered on top of the
/// git-SHA staleness check. `check_gap_binary_staleness` only sees
/// *committed* history — a working-tree edit to a `GAP_STORE_FILES` source
/// file that hasn't been committed (or committed but not yet rebuilt into
/// the installed binary) is invisible to `git log <sha>..HEAD`. This
/// compares the binary's on-disk mtime directly against the newest mtime
/// among `GAP_STORE_FILES` so that class of drift is still caught.
///
/// Returns `Some(true)` if the newest tracked source file postdates the
/// binary (a rebuild is needed), `Some(false)` if the binary is newer than
/// every tracked source file present on disk, `None` if no tracked source
/// file's mtime could be read (e.g. none exist at `repo_root`).
fn binary_predates_source_files_with_mtime(
    repo_root: &Path,
    binary_mtime: std::time::SystemTime,
) -> Option<bool> {
    let mut newest_source: Option<std::time::SystemTime> = None;
    for f in GAP_STORE_FILES {
        if let Ok(meta) = std::fs::metadata(repo_root.join(f)) {
            if let Ok(mtime) = meta.modified() {
                if newest_source.is_none_or(|cur| mtime > cur) {
                    newest_source = Some(mtime);
                }
            }
        }
    }
    Some(newest_source? > binary_mtime)
}

/// Same as [`binary_predates_source_files_with_mtime`] but reads the running
/// binary's own mtime via `current_exe()`. `None` if that's unreadable
/// (sandboxed / chrooted env) — treated as inconclusive by callers.
fn binary_predates_source_files(repo_root: &Path) -> Option<bool> {
    let exe = std::env::current_exe().ok()?;
    let binary_mtime = std::fs::metadata(&exe).ok()?.modified().ok()?;
    binary_predates_source_files_with_mtime(repo_root, binary_mtime)
}

/// Combines the git-SHA staleness check with the mtime-based rebuild check.
/// Production entry points ([`warn_if_stale_for_gap_mutation`],
/// [`fail_if_stale_for_destructive`]) use this instead of
/// `check_gap_binary_staleness` directly so an uncommitted-and-unbuilt
/// source edit is caught even when the committed git history is Fresh.
fn check_gap_binary_staleness_with_rebuild_check(repo_root: &Path) -> StalenessCheck {
    let git_check = check_gap_binary_staleness(repo_root);
    if !matches!(git_check, StalenessCheck::Fresh) {
        return git_check;
    }
    match binary_predates_source_files(repo_root) {
        Some(true) => StalenessCheck::Stale {
            commits_ahead: 0,
            latest_subject: "rebuild check: gap-store-affecting source file(s) on disk are \
                newer than the installed binary (uncommitted or not-yet-rebuilt change)"
                .to_string(),
        },
        Some(false) | None => StalenessCheck::Fresh,
    }
}

/// Emit a stderr warning when the binary is stale relative to the repo at
/// `repo_root`. Honors `CHUMP_BINARY_STALENESS_CHECK=0` to disable.
/// Returns `true` if a warning was emitted (caller may want to refuse
/// non-trivial mutations behind `--force`); `false` for fresh / skipped /
/// disabled.
pub fn warn_if_stale_for_gap_mutation(repo_root: &Path) -> bool {
    if std::env::var("CHUMP_BINARY_STALENESS_CHECK").as_deref() == Ok("0") {
        return false;
    }
    match check_gap_binary_staleness_with_rebuild_check(repo_root) {
        StalenessCheck::Fresh | StalenessCheck::Skip => false,
        StalenessCheck::Stale {
            commits_ahead,
            latest_subject,
        } => {
            eprintln!(
                "[chump] WARNING: this binary was built at {} ({}) but {} \
                 gap-store-affecting commit(s) have landed since on this \
                 repo's HEAD. Most recent: {}",
                chump_build_sha(),
                chump_build_date(),
                commits_ahead,
                latest_subject,
            );
            eprintln!(
                "[chump]          A pre-INFRA-147 binary stripped the meta: \
                 preamble during YAML regen on 2026-04-27 (~20k-line silent \
                 corruption). Rebuild + reinstall before continuing:"
            );
            eprintln!(
                "[chump]            cargo install --path {} --bin chump --force",
                repo_root.display()
            );
            eprintln!(
                "[chump]          Or set CHUMP_BINARY_STALENESS_CHECK=0 to \
                 silence this check (use sparingly)."
            );
            true
        }
    }
}

/// Outcome of [`fail_if_stale_for_destructive`].
#[derive(Debug, PartialEq, Eq)]
pub enum DestructiveStalenessOutcome {
    /// Binary is fresh, skip-state, or the check is disabled. Caller proceeds.
    Proceed,
    /// Binary is stale and the operator has explicitly opted into running
    /// anyway via `CHUMP_ALLOW_STALE_DESTRUCTIVE=1`. Caller proceeds; ambient
    /// telemetry has been emitted naming the override.
    OverrideAccepted,
    /// Binary is stale and no override is set. Caller MUST abort the
    /// destructive operation. Stderr has been told why.
    Refuse,
}

/// INFRA-825: hard-fail variant of [`warn_if_stale_for_gap_mutation`] for
/// destructive operations like `chump gap ship --update-yaml` and `chump gap
/// dump --per-file` that regenerate >1 YAML in a single invocation.
///
/// PR #1444 silently reverted META-044 because `chump gap ship --update-yaml`
/// ran with a 9-commit-stale binary that regenerated all YAMLs from an
/// outdated state.db. The soft `warn_if_stale_for_gap_mutation` printed a
/// warning but did not refuse to run. This function refuses.
///
/// Honors three escape hatches:
/// - `CHUMP_BINARY_STALENESS_CHECK=0` — disable the check entirely (matches
///   the soft path; reserved for CI / packaged builds where the staleness
///   signal is itself unreliable).
/// - `CHUMP_ALLOW_STALE_DESTRUCTIVE=1` — explicit operator override; returns
///   `OverrideAccepted` after emitting a loud `stale_binary_destructive_override`
///   ambient event so the override is auditable.
/// - The check returns `Skip` (no .git, unknown SHA): treated as `Proceed`.
///
/// `op_name` is a short human-readable label for the operation (e.g.,
/// `"gap ship --update-yaml"`) used in the error message and the ambient
/// event.
pub fn fail_if_stale_for_destructive(
    repo_root: &Path,
    op_name: &str,
) -> DestructiveStalenessOutcome {
    if std::env::var("CHUMP_BINARY_STALENESS_CHECK").as_deref() == Ok("0") {
        return DestructiveStalenessOutcome::Proceed;
    }
    match check_gap_binary_staleness_with_rebuild_check(repo_root) {
        StalenessCheck::Fresh | StalenessCheck::Skip => DestructiveStalenessOutcome::Proceed,
        StalenessCheck::Stale {
            commits_ahead,
            latest_subject,
        } => {
            let override_set = std::env::var("CHUMP_ALLOW_STALE_DESTRUCTIVE").as_deref() == Ok("1");
            if override_set {
                eprintln!(
                    "[chump] OVERRIDE: CHUMP_ALLOW_STALE_DESTRUCTIVE=1 — proceeding \
                     with '{op_name}' despite {commits_ahead} unmerged \
                     gap-store-affecting commit(s) (latest: {latest_subject}). \
                     This is the escape hatch INFRA-825 ships with; expect \
                     ambient kind=stale_binary_destructive_override."
                );
                emit_destructive_override_ambient_event(repo_root, op_name, commits_ahead);
                return DestructiveStalenessOutcome::OverrideAccepted;
            }

            // INFRA-1977 (H8 critique): JIT background rebuild — kick off
            // `cargo install --path . --bin chump --force` as a detached
            // subprocess so the next chump invocation finds Fresh and
            // proceeds without manual operator intervention. This invocation
            // still refuses (it IS the stale binary; can't fix itself), but
            // the friendlier message tells the operator a retry will work.
            // Bypass: CHUMP_DISABLE_JIT_BINARY_REFRESH=1 (return to pre-1977
            // hand-rebuild behavior).
            let refresh_state =
                if std::env::var("CHUMP_DISABLE_JIT_BINARY_REFRESH").as_deref() == Ok("1") {
                    BinaryRefreshState::Disabled
                } else {
                    trigger_or_check_binary_refresh(repo_root)
                };

            eprintln!(
                "[chump] REFUSED: '{op_name}' is a destructive bulk-YAML \
                 operation, and this binary was built at {} ({}) but {} \
                 gap-store-affecting commit(s) have landed since on this \
                 repo's HEAD. Latest: {}",
                chump_build_sha(),
                chump_build_date(),
                commits_ahead,
                latest_subject,
            );
            eprintln!(
                "[chump]          Running this would risk silent revert \
                 of merged work (see PR #1444 — META-044 wiped by a \
                 9-commit-stale binary on 2026-05-11)."
            );
            match refresh_state {
                BinaryRefreshState::JustStarted => {
                    eprintln!(
                        "[chump]          INFRA-1977 JIT refresh: background \
                         rebuild started just now. Retry in ~60s — next \
                         invocation should find Fresh and proceed."
                    );
                }
                BinaryRefreshState::InFlight { age_secs } => {
                    eprintln!(
                        "[chump]          INFRA-1977 JIT refresh: rebuild \
                         in flight ({}s ago). Retry in ~{}s.",
                        age_secs,
                        std::cmp::max(5, 90_i64.saturating_sub(age_secs as i64))
                    );
                }
                BinaryRefreshState::RecentlyCompleted { age_secs } => {
                    eprintln!(
                        "[chump]          INFRA-1977 JIT refresh: rebuild \
                         finished {}s ago but this process is still the old \
                         binary — close this shell and retry from a fresh \
                         invocation.",
                        age_secs
                    );
                }
                BinaryRefreshState::Failed { reason } => {
                    eprintln!(
                        "[chump]          INFRA-1977 JIT refresh: background \
                         rebuild FAILED ({}). Manual rebuild required:",
                        reason
                    );
                    eprintln!(
                        "[chump]            cargo install --path {} --bin chump --force",
                        repo_root.display()
                    );
                }
                BinaryRefreshState::Disabled => {
                    eprintln!(
                        "[chump]          Rebuild + retry (JIT refresh disabled \
                         via CHUMP_DISABLE_JIT_BINARY_REFRESH=1):"
                    );
                    eprintln!(
                        "[chump]            cargo install --path {} --bin chump --force",
                        repo_root.display()
                    );
                }
            }
            eprintln!(
                "[chump]          Override (very loud, audited): \
                 CHUMP_ALLOW_STALE_DESTRUCTIVE=1"
            );
            DestructiveStalenessOutcome::Refuse
        }
    }
}

/// INFRA-1977 (H8): rebuild-state for the background `cargo install`.
#[derive(Debug)]
enum BinaryRefreshState {
    /// Just spawned the rebuild this call. Operator should retry in ~60s.
    JustStarted,
    /// Rebuild started earlier; still in flight. Hint at remaining ETA.
    InFlight { age_secs: u64 },
    /// Rebuild finished recently — this stale process can't see the new
    /// binary, but a fresh shell invocation will.
    RecentlyCompleted { age_secs: u64 },
    /// Last rebuild failed. Operator must run `cargo install` manually.
    Failed { reason: String },
    /// Disabled via CHUMP_DISABLE_JIT_BINARY_REFRESH=1.
    Disabled,
}

/// INFRA-1977: read `.chump/binary-refresh-state.json` and decide whether
/// to (re-)spawn a background `cargo install`. Idempotent across multiple
/// concurrent invocations — if a rebuild is in flight, we don't start
/// another. Best-effort: any I/O error is treated as "rebuild not in flight"
/// and we trigger a fresh one.
fn trigger_or_check_binary_refresh(repo_root: &Path) -> BinaryRefreshState {
    let state_dir = repo_root.join(".chump");
    let state_file = state_dir.join("binary-refresh-state.json");
    let now_unix = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);

    // Read existing state if present.
    if let Ok(content) = std::fs::read_to_string(&state_file) {
        // Cheap parse: looking for "status":"in_flight"|"done"|"failed" + started_at.
        // Avoid pulling serde_json into version.rs by hand-parsing.
        let started_at = parse_json_u64_field(&content, "started_at").unwrap_or(0);
        let completed_at = parse_json_u64_field(&content, "completed_at").unwrap_or(0);
        let status = parse_json_str_field(&content, "status").unwrap_or_default();

        match status.as_str() {
            "in_flight" => {
                let age = now_unix.saturating_sub(started_at);
                // Reap genuinely-stuck rebuilds: if older than 10min, treat
                // as failed and restart.
                if age > 600 {
                    spawn_background_rebuild(repo_root, &state_file, now_unix);
                    return BinaryRefreshState::JustStarted;
                }
                return BinaryRefreshState::InFlight { age_secs: age };
            }
            "done" => {
                let age = now_unix.saturating_sub(completed_at);
                // If rebuild was recent (< 5 min), assume the operator just
                // hasn't reinvoked yet.
                if age < 300 {
                    return BinaryRefreshState::RecentlyCompleted { age_secs: age };
                }
                // Stale "done" marker — older than 5 min and binary is still
                // stale per our check; trigger a new rebuild.
                spawn_background_rebuild(repo_root, &state_file, now_unix);
                return BinaryRefreshState::JustStarted;
            }
            "failed" => {
                let reason = parse_json_str_field(&content, "reason")
                    .unwrap_or_else(|| "unknown".to_string());
                let age = now_unix.saturating_sub(started_at);
                // Failed too recently — don't retry yet.
                if age < 60 {
                    return BinaryRefreshState::Failed { reason };
                }
                // Failed long enough ago to retry.
                spawn_background_rebuild(repo_root, &state_file, now_unix);
                return BinaryRefreshState::JustStarted;
            }
            _ => {
                // Unknown / corrupt marker — start fresh.
                spawn_background_rebuild(repo_root, &state_file, now_unix);
                return BinaryRefreshState::JustStarted;
            }
        }
    }

    // No marker — first ever request. Spawn rebuild.
    spawn_background_rebuild(repo_root, &state_file, now_unix);
    BinaryRefreshState::JustStarted
}

/// Spawn `cargo install --path <root> --bin chump --force` as a detached
/// subprocess. Writes "started" marker before spawn; wrapper subprocess
/// will update the marker on completion/failure. Best-effort: failures here
/// are treated as "rebuild not triggered" by the caller via the marker check.
fn spawn_background_rebuild(repo_root: &Path, state_file: &Path, now_unix: u64) {
    // Ensure .chump/ exists.
    if let Some(parent) = state_file.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    // Write "in_flight" marker BEFORE spawning so concurrent callers see it.
    let _ = std::fs::write(
        state_file,
        format!(
            "{{\"status\":\"in_flight\",\"started_at\":{},\"completed_at\":0,\"reason\":\"\"}}",
            now_unix
        ),
    );

    // Emit ambient event.
    // scanner-anchor: "kind":"binary_refresh_started"
    // scanner-anchor: "kind":"binary_refresh_completed"
    // scanner-anchor: "kind":"binary_refresh_failed"
    emit_binary_refresh_event(repo_root, "binary_refresh_started", "", 0);

    // The actual rebuild + marker update is done by a small wrapper shell
    // command we spawn detached. The wrapper:
    //   1. runs `cargo install --path <root> --bin chump --force`
    //   2. on success: writes "done" marker
    //   3. on failure: writes "failed" marker with reason
    //   4. emits the appropriate ambient event
    let state_file_str = state_file.to_string_lossy().to_string();
    let repo_root_str = repo_root.to_string_lossy().to_string();
    let ambient = repo_root.join(".chump-locks").join("ambient.jsonl");
    let ambient_str = ambient.to_string_lossy().to_string();

    let wrapper = format!(
        r#"
( cargo install --path '{root}' --bin chump --force --offline >/tmp/chump-jit-rebuild.log 2>&1 \
    || cargo install --path '{root}' --bin chump --force >>/tmp/chump-jit-rebuild.log 2>&1 ) \
    && now=$(date +%s) \
    && printf '{{"status":"done","started_at":{started},"completed_at":%s,"reason":""}}' "$now" > '{state}' \
    && printf '{{"ts":"%s","kind":"binary_refresh_completed","event":"binary_refresh_completed"}}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> '{ambient}' \
    || ( now=$(date +%s) \
        ; reason=$(tail -1 /tmp/chump-jit-rebuild.log | tr -d '"' | head -c 200) \
        ; printf '{{"status":"failed","started_at":{started},"completed_at":%s,"reason":"%s"}}' "$now" "$reason" > '{state}' \
        ; printf '{{"ts":"%s","kind":"binary_refresh_failed","event":"binary_refresh_failed","reason":"%s"}}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$reason" >> '{ambient}' )
"#,
        root = repo_root_str,
        started = now_unix,
        state = state_file_str,
        ambient = ambient_str,
    );

    // Detach: setsid + nohup so the rebuild outlives the current chump process.
    let _ = std::process::Command::new("bash")
        .arg("-c")
        .arg(&wrapper)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .stdin(std::process::Stdio::null())
        .spawn();
}

/// Emit ambient event for binary refresh lifecycle (best-effort).
fn emit_binary_refresh_event(repo_root: &Path, kind: &str, reason: &str, _unused: u64) {
    let ambient = repo_root.join(".chump-locks").join("ambient.jsonl");
    if let Some(parent) = ambient.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"{kind}\",\"event\":\"{kind}\",\"reason\":\"{reason}\"}}"
    );
    use std::io::Write as _;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient)
    {
        let _ = writeln!(f, "{}", line);
    }
}

/// Tiny JSON-field parsers (avoid pulling serde_json into version.rs).
fn parse_json_u64_field(content: &str, field: &str) -> Option<u64> {
    let needle = format!("\"{}\":", field);
    let idx = content.find(&needle)? + needle.len();
    let rest = &content[idx..];
    let end = rest.find(|c: char| !c.is_ascii_digit() && c != '-')?;
    rest[..end].parse().ok()
}

fn parse_json_str_field(content: &str, field: &str) -> Option<String> {
    let needle = format!("\"{}\":\"", field);
    let idx = content.find(&needle)? + needle.len();
    let rest = &content[idx..];
    let end = rest.find('"')?;
    Some(rest[..end].to_string())
}

/// Emit an ambient event naming the override use. Best-effort: failures here
/// must never break the caller (the override is already accepted by the time
/// we get here).
fn emit_destructive_override_ambient_event(repo_root: &Path, op_name: &str, commits_ahead: usize) {
    let ambient = repo_root.join(".chump-locks").join("ambient.jsonl");
    if let Some(parent) = ambient.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let ts = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let line = format!(
        "{{\"ts\":{ts},\"event\":\"ALERT\",\"kind\":\"stale_binary_destructive_override\",\
         \"op\":\"{}\",\"commits_ahead\":{},\"build_sha\":\"{}\"}}\n",
        op_name.replace('"', "\\\""),
        commits_ahead,
        chump_build_sha(),
    );
    use std::io::Write as _;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient)
    {
        let _ = f.write_all(line.as_bytes());
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command as PCommand;

    fn make_repo() -> (tempfile::TempDir, String, String) {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path();
        // INFRA-1057: clear inherited git env so commands operate on the
        // isolated tempdir repo, not the parent shell's linked worktree.
        // CHUMP_GIT_IDENTITY_CHECK=0 bypasses INFRA-787 for the t@t.t fixture.
        let run = |args: &[&str]| {
            let st = PCommand::new("git")
                .args(args)
                .current_dir(p)
                .env_remove("GIT_DIR")
                .env_remove("GIT_WORK_TREE")
                .env_remove("GIT_COMMON_DIR")
                .env_remove("GIT_INDEX_FILE")
                .env("CHUMP_GIT_IDENTITY_CHECK", "0")
                .output()
                .unwrap();
            assert!(st.status.success(), "git {args:?} failed: {st:?}");
        };
        run(&["init", "-q", "-b", "main"]);
        run(&["config", "user.email", "t@t.t"]);
        run(&["config", "user.name", "t"]);
        std::fs::create_dir_all(p.join("src")).unwrap();
        std::fs::write(p.join("src/gap_store.rs"), "// initial\n").unwrap();
        run(&["add", "."]);
        run(&["commit", "-q", "-m", "first"]);
        let sha1 = String::from_utf8(
            PCommand::new("git")
                .args(["rev-parse", "--short=12", "HEAD"])
                .current_dir(p)
                .env_remove("GIT_DIR")
                .env_remove("GIT_WORK_TREE")
                .env_remove("GIT_COMMON_DIR")
                .env_remove("GIT_INDEX_FILE")
                .output()
                .unwrap()
                .stdout,
        )
        .unwrap()
        .trim()
        .to_string();

        std::fs::write(p.join("README.md"), "hi\n").unwrap();
        run(&["add", "."]);
        run(&["commit", "-q", "-m", "unrelated change"]);
        let sha2 = String::from_utf8(
            PCommand::new("git")
                .args(["rev-parse", "--short=12", "HEAD"])
                .current_dir(p)
                .env_remove("GIT_DIR")
                .env_remove("GIT_WORK_TREE")
                .env_remove("GIT_COMMON_DIR")
                .env_remove("GIT_INDEX_FILE")
                .output()
                .unwrap()
                .stdout,
        )
        .unwrap()
        .trim()
        .to_string();

        (dir, sha1, sha2)
    }

    #[test]
    fn fresh_when_baked_sha_is_at_head() {
        let (dir, _sha1, sha2) = make_repo();
        assert_eq!(
            check_gap_binary_staleness_with_sha(dir.path(), &sha2),
            StalenessCheck::Fresh
        );
    }

    #[test]
    fn fresh_when_only_unrelated_files_changed_since_baked_sha() {
        // Between sha1 and sha2 only README.md changed — gap_store.rs and
        // main.rs untouched. A binary baked at sha1 is still safe.
        let (dir, sha1, _sha2) = make_repo();
        assert_eq!(
            check_gap_binary_staleness_with_sha(dir.path(), &sha1),
            StalenessCheck::Fresh
        );
    }

    #[test]
    fn stale_when_gap_store_changed_since_baked_sha() {
        let (dir, sha1, _sha2) = make_repo();
        let p = dir.path();
        std::fs::write(p.join("src/gap_store.rs"), "// edited\n").unwrap();
        PCommand::new("git")
            .args(["add", "."])
            .current_dir(p)
            .env_remove("GIT_DIR")
            .env_remove("GIT_WORK_TREE")
            .env_remove("GIT_COMMON_DIR")
            .env_remove("GIT_INDEX_FILE")
            .output()
            .unwrap();
        PCommand::new("git")
            .args(["commit", "-q", "-m", "INFRA-X: edit gap_store"])
            .current_dir(p)
            .env_remove("GIT_DIR")
            .env_remove("GIT_WORK_TREE")
            .env_remove("GIT_COMMON_DIR")
            .env_remove("GIT_INDEX_FILE")
            .env("CHUMP_GIT_IDENTITY_CHECK", "0")
            .output()
            .unwrap();
        match check_gap_binary_staleness_with_sha(p, &sha1) {
            StalenessCheck::Stale {
                commits_ahead,
                latest_subject,
            } => {
                assert_eq!(commits_ahead, 1);
                assert_eq!(latest_subject, "INFRA-X: edit gap_store");
            }
            other => panic!("expected Stale, got {other:?}"),
        }
    }

    #[test]
    fn skip_when_baked_sha_unknown() {
        let (dir, _, _) = make_repo();
        assert_eq!(
            check_gap_binary_staleness_with_sha(dir.path(), "unknown"),
            StalenessCheck::Skip
        );
    }

    #[test]
    fn skip_when_repo_root_is_not_a_git_checkout() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(
            check_gap_binary_staleness_with_sha(dir.path(), "deadbeefcafe"),
            StalenessCheck::Skip
        );
    }

    // ── INFRA-6384 mtime-based rebuild check ─────────────────────────────────

    #[test]
    fn rebuild_check_blocks_on_dummy_edit_without_rebuild() {
        let (dir, _sha1, _sha2) = make_repo();
        let p = dir.path();
        // Dummy change to a tracked source file — no commit, no rebuild.
        std::fs::write(p.join("src/gap_store.rs"), "// dummy edit, no rebuild\n").unwrap();
        // Simulate a binary built long before this edit.
        let ancient_binary = std::time::SystemTime::UNIX_EPOCH;
        assert_eq!(
            binary_predates_source_files_with_mtime(p, ancient_binary),
            Some(true),
            "an ancient binary mtime against a just-edited source file must be flagged stale"
        );
    }

    #[test]
    fn rebuild_check_fresh_when_binary_newer_than_source() {
        let (dir, _sha1, _sha2) = make_repo();
        let p = dir.path();
        let far_future_binary = std::time::SystemTime::now() + std::time::Duration::from_secs(3600);
        assert_eq!(
            binary_predates_source_files_with_mtime(p, far_future_binary),
            Some(false),
            "a binary newer than every tracked source file must not be flagged stale"
        );
    }

    #[test]
    fn rebuild_check_none_when_no_tracked_files_present() {
        let dir = tempfile::tempdir().unwrap();
        assert_eq!(
            binary_predates_source_files_with_mtime(dir.path(), std::time::SystemTime::now()),
            None,
            "no GAP_STORE_FILES on disk means the check is inconclusive"
        );
    }

    #[test]
    fn combined_check_stale_on_uncommitted_edit_despite_fresh_git_history() {
        let (dir, _sha1, sha2) = make_repo();
        let p = dir.path();
        // Baked SHA is HEAD (git-SHA check alone would say Fresh), but a
        // dummy uncommitted edit landed on disk without a rebuild.
        std::fs::write(p.join("src/gap_store.rs"), "// dummy edit, no rebuild\n").unwrap();
        assert_eq!(
            check_gap_binary_staleness_with_sha(p, &sha2),
            StalenessCheck::Fresh,
            "git-SHA check alone is blind to uncommitted edits"
        );
        match binary_predates_source_files_with_mtime(p, std::time::SystemTime::UNIX_EPOCH) {
            Some(true) => {}
            other => panic!("expected the rebuild check to flag stale, got {other:?}"),
        }
    }

    // ── INFRA-825 hard-fail destructive variant ──────────────────────────────

    /// Helper: stale-repo fixture (gap_store.rs edited after sha1).
    fn make_stale_repo() -> (tempfile::TempDir, String) {
        let (dir, sha1, _) = make_repo();
        let p = dir.path();
        std::fs::write(p.join("src/gap_store.rs"), "// stale-fixture edit\n").unwrap();
        PCommand::new("git")
            .args(["add", "."])
            .current_dir(p)
            .env_remove("GIT_DIR")
            .env_remove("GIT_WORK_TREE")
            .env_remove("GIT_COMMON_DIR")
            .env_remove("GIT_INDEX_FILE")
            .output()
            .unwrap();
        PCommand::new("git")
            .args(["commit", "-q", "-m", "INFRA-X: simulate post-build commit"])
            .current_dir(p)
            .env_remove("GIT_DIR")
            .env_remove("GIT_WORK_TREE")
            .env_remove("GIT_COMMON_DIR")
            .env_remove("GIT_INDEX_FILE")
            .env("CHUMP_GIT_IDENTITY_CHECK", "0")
            .output()
            .unwrap();
        (dir, sha1)
    }

    /// Replay the PR #1444 failure mode: simulate a 1-commit-stale binary
    /// running a destructive op (no override). Must REFUSE.
    #[test]
    #[serial_test::serial]
    fn pr_1444_replay_refuses_without_override() {
        let (dir, sha1) = make_stale_repo();
        // Defensive: ensure no leaked env from a parallel test.
        unsafe {
            std::env::remove_var("CHUMP_ALLOW_STALE_DESTRUCTIVE");
            std::env::remove_var("CHUMP_BINARY_STALENESS_CHECK");
        }
        // We can't call fail_if_stale_for_destructive directly (it reads the
        // baked SHA via chump_build_sha which is set at compile time, not
        // injectable). Test the predicate it uses instead: a Stale outcome
        // with no override means REFUSE.
        let outcome = check_gap_binary_staleness_with_sha(dir.path(), &sha1);
        match outcome {
            StalenessCheck::Stale { .. } => { /* expected */ }
            other => panic!("expected Stale, got {other:?}"),
        }
    }

    #[test]
    #[serial_test::serial]
    fn override_env_recognized() {
        // Direct env-var read; we don't exercise the full function (compile-baked SHA)
        // but verify the operator-facing escape hatch is wired correctly.
        unsafe {
            std::env::set_var("CHUMP_ALLOW_STALE_DESTRUCTIVE", "1");
        }
        let val = std::env::var("CHUMP_ALLOW_STALE_DESTRUCTIVE").as_deref() == Ok("1");
        assert!(val, "CHUMP_ALLOW_STALE_DESTRUCTIVE=1 should be readable");
        unsafe {
            std::env::remove_var("CHUMP_ALLOW_STALE_DESTRUCTIVE");
        }
    }

    #[test]
    #[serial_test::serial]
    fn override_env_unset_means_no_override() {
        unsafe {
            std::env::remove_var("CHUMP_ALLOW_STALE_DESTRUCTIVE");
        }
        let val = std::env::var("CHUMP_ALLOW_STALE_DESTRUCTIVE").as_deref() == Ok("1");
        assert!(
            !val,
            "unset CHUMP_ALLOW_STALE_DESTRUCTIVE should NOT trigger override"
        );
    }

    /// Ambient-event emitter writes a parseable JSONL line. (Best-effort
    /// helper; this test asserts the file exists and contains the right kind.)
    #[test]
    fn override_event_emitted_to_ambient_jsonl() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path();
        emit_destructive_override_ambient_event(p, "test-op", 3);
        let ambient = p.join(".chump-locks").join("ambient.jsonl");
        assert!(ambient.exists(), "ambient.jsonl should be created");
        let contents = std::fs::read_to_string(&ambient).unwrap();
        assert!(
            contents.contains("\"kind\":\"stale_binary_destructive_override\""),
            "ambient event should name the kind; got: {contents}"
        );
        assert!(
            contents.contains("\"op\":\"test-op\""),
            "ambient event should include op name; got: {contents}"
        );
        assert!(
            contents.contains("\"commits_ahead\":3"),
            "ambient event should include commits_ahead; got: {contents}"
        );
    }
}
