//! CREDIBLE-030: CLI dispatch + arg parsing tests for src/main.rs
//!
//! Two layers:
//!   1. Source-level: verify the 5 highest-traffic subcommand match arms
//!      exist in src/main.rs (dispatch_table_complete).
//!   2. Binary-level (process spawn): happy path + error path for each
//!      subcommand. Each test uses an isolated tempdir with CHUMP_REPO /
//!      CHUMP_HOME overridden so real state.db is never touched.
//!
//! Run: cargo test --test main_dispatch

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

// ── helpers ───────────────────────────────────────────────────────────────────

fn chump_bin() -> String {
    env!("CARGO_BIN_EXE_chump").to_string()
}

fn main_rs_src() -> String {
    let manifest = env!("CARGO_MANIFEST_DIR");
    let p = PathBuf::from(manifest).join("src/main.rs");
    fs::read_to_string(p).expect("read src/main.rs")
}

/// Minimal repo layout that chump needs in a tempdir.
fn setup_isolated_repo(dir: &Path) {
    Command::new("git")
        .args(["init", "--quiet"])
        .current_dir(dir)
        .status()
        .expect("git init");
    fs::create_dir_all(dir.join("docs/gaps")).unwrap();
    fs::create_dir_all(dir.join(".chump-locks")).unwrap();
    fs::create_dir_all(dir.join(".chump")).unwrap();
}

/// Env block that redirects all chump I/O to an isolated dir.
fn isolation_env(root: &Path) -> Vec<(String, String)> {
    let r = root.to_str().unwrap().to_string();
    vec![
        ("CHUMP_REPO".into(), r.clone()),
        ("CHUMP_HOME".into(), r.clone()),
        // Isolate HOME too: the RESILIENT-069 farmer gate resolves the
        // oauth-token.json under $HOME/.chump, so without this a stale token in
        // the developer's real ~/.chump makes farmer RED and every reserve/ship
        // test fail. An empty tempdir HOME has no token -> farmer fails open
        // (green), so the tests exercise gap mechanics deterministically.
        ("HOME".into(), r.clone()),
        ("CHUMP_RESERVE_SCAN_OPEN_PRS".into(), "0".into()),
        ("CHUMP_RESERVE_NO_AUTOSTAGE".into(), "1".into()),
        ("CHUMP_RAW_YAML_LOCK".into(), "0".into()),
        ("FLEET_029_AMBIENT_GLANCE_SKIP".into(), "1".into()),
        (
            "CHUMP_SESSION_ID".into(),
            format!("test-{}", std::process::id()),
        ),
        ("CHUMP_GAP_SHIP_SKIP_STALE_CHECK".into(), "1".into()),
    ]
}

fn run(dir: &Path, args: &[&str]) -> Output {
    let bin = chump_bin();
    let mut cmd = Command::new(&bin);
    cmd.current_dir(dir);
    for (k, v) in isolation_env(dir) {
        cmd.env(k, v);
    }
    cmd.args(args)
        .output()
        .unwrap_or_else(|e| panic!("spawn {args:?}: {e}"))
}

fn stdout(o: &Output) -> String {
    String::from_utf8_lossy(&o.stdout).into_owned()
}

fn stderr(o: &Output) -> String {
    String::from_utf8_lossy(&o.stderr).into_owned()
}

/// Reserve a gap and return its ID (panics if reserve fails).
fn reserve_gap(dir: &Path, domain: &str, title: &str) -> String {
    let out = run(
        dir,
        &["gap", "reserve", "--domain", domain, "--title", title],
    );
    assert!(out.status.success(), "gap reserve failed: {}", stderr(&out));
    stdout(&out).trim().to_string()
}

// ── 1. dispatch table (source level) ─────────────────────────────────────────

#[test]
fn dispatch_table_complete_reserve() {
    let src = main_rs_src();
    assert!(
        src.contains("\"reserve\" =>") || src.contains("\"reserve\"=>"),
        "src/main.rs missing 'reserve' match arm"
    );
}

#[test]
fn dispatch_table_complete_show() {
    let src = main_rs_src();
    assert!(
        src.contains("\"show\" =>") || src.contains("\"show\"=>"),
        "src/main.rs missing 'show' match arm"
    );
}

#[test]
fn dispatch_table_complete_list() {
    let src = main_rs_src();
    assert!(
        src.contains("\"list\" =>") || src.contains("\"list\"=>"),
        "src/main.rs missing 'list' match arm"
    );
}

#[test]
fn dispatch_table_complete_ship() {
    let src = main_rs_src();
    assert!(
        src.contains("\"ship\" =>") || src.contains("\"ship\"=>"),
        "src/main.rs missing 'ship' match arm"
    );
}

#[test]
fn dispatch_table_complete_claim() {
    let src = main_rs_src();
    // claim is handled at the top-level arg expansion, not as a gap subcommand.
    assert!(
        src.contains("\"claim\"") || src.contains("claim"),
        "src/main.rs missing claim dispatch"
    );
}

// ── 2. gap reserve ────────────────────────────────────────────────────────────

#[test]
fn gap_reserve_valid_returns_gap_id() {
    let dir = tempfile::tempdir().unwrap();
    setup_isolated_repo(dir.path());
    let out = run(
        dir.path(),
        &[
            "gap",
            "reserve",
            "--domain",
            "INFRA",
            "--title",
            "dispatch test",
        ],
    );
    assert!(out.status.success(), "reserve failed: {}", stderr(&out));
    let id = stdout(&out).trim().to_string();
    assert!(id.starts_with("INFRA-"), "expected INFRA-NNN, got {:?}", id);
}

#[test]
fn gap_reserve_missing_domain_exits_2() {
    let dir = tempfile::tempdir().unwrap();
    setup_isolated_repo(dir.path());
    let out = run(dir.path(), &["gap", "reserve"]);
    assert_eq!(
        out.status.code(),
        Some(2),
        "expected exit 2, got {:?}",
        out.status
    );
    assert!(
        stderr(&out).to_ascii_lowercase().contains("usage"),
        "expected usage hint in stderr, got {:?}",
        stderr(&out)
    );
}

#[test]
fn gap_reserve_missing_title_with_domain_flag_exits_2() {
    let dir = tempfile::tempdir().unwrap();
    setup_isolated_repo(dir.path());
    let out = run(dir.path(), &["gap", "reserve", "--domain", "INFRA"]);
    assert_eq!(
        out.status.code(),
        Some(2),
        "expected exit 2 for missing --title"
    );
    assert!(
        stderr(&out).contains("--title"),
        "expected --title hint in stderr, got {:?}",
        stderr(&out)
    );
}

// ── 3. gap list ───────────────────────────────────────────────────────────────

#[test]
fn gap_list_empty_exits_0() {
    let dir = tempfile::tempdir().unwrap();
    setup_isolated_repo(dir.path());
    let out = run(dir.path(), &["gap", "list"]);
    assert!(out.status.success(), "gap list failed: {}", stderr(&out));
}

#[test]
fn gap_list_json_returns_array() {
    let dir = tempfile::tempdir().unwrap();
    setup_isolated_repo(dir.path());
    // Seed one gap so the JSON is non-trivial.
    reserve_gap(dir.path(), "INFRA", "test-list-json");
    let out = run(dir.path(), &["gap", "list", "--json"]);
    assert!(
        out.status.success(),
        "gap list --json failed: {}",
        stderr(&out)
    );
    let json: serde_json::Value =
        serde_json::from_str(stdout(&out).trim()).expect("gap list --json must emit valid JSON");
    assert!(json.is_array(), "gap list --json must return a JSON array");
    let arr = json.as_array().unwrap();
    assert!(
        !arr.is_empty(),
        "JSON array should have at least the seeded gap"
    );
}

#[test]
fn gap_list_status_filter_open() {
    let dir = tempfile::tempdir().unwrap();
    setup_isolated_repo(dir.path());
    reserve_gap(dir.path(), "INFRA", "test-status-filter");
    let out = run(dir.path(), &["gap", "list", "--status", "open", "--json"]);
    assert!(
        out.status.success(),
        "gap list --status open failed: {}",
        stderr(&out)
    );
    let json: serde_json::Value = serde_json::from_str(stdout(&out).trim()).unwrap();
    let arr = json.as_array().unwrap();
    for item in arr {
        assert_eq!(
            item["status"].as_str(),
            Some("open"),
            "all items in --status open must be open"
        );
    }
}

// ── 4. gap show ───────────────────────────────────────────────────────────────

#[test]
fn gap_show_valid_id_exits_0() {
    let dir = tempfile::tempdir().unwrap();
    setup_isolated_repo(dir.path());
    let id = reserve_gap(dir.path(), "INFRA", "test-show");
    let out = run(dir.path(), &["gap", "show", &id]);
    assert!(
        out.status.success(),
        "gap show {id} failed: {}",
        stderr(&out)
    );
    let out_str = stdout(&out);
    assert!(
        out_str.contains(&id),
        "gap show output must contain the gap ID"
    );
}

#[test]
fn gap_show_json_contains_id_field() {
    let dir = tempfile::tempdir().unwrap();
    setup_isolated_repo(dir.path());
    let id = reserve_gap(dir.path(), "INFRA", "test-show-json");
    let out = run(dir.path(), &["gap", "show", &id, "--json"]);
    assert!(
        out.status.success(),
        "gap show --json failed: {}",
        stderr(&out)
    );
    let json: serde_json::Value =
        serde_json::from_str(stdout(&out).trim()).expect("gap show --json must emit valid JSON");
    assert_eq!(
        json["id"].as_str(),
        Some(id.as_str()),
        "JSON id field must match"
    );
}

#[test]
fn gap_show_missing_id_exits_2() {
    let dir = tempfile::tempdir().unwrap();
    setup_isolated_repo(dir.path());
    let out = run(dir.path(), &["gap", "show"]);
    assert_eq!(
        out.status.code(),
        Some(2),
        "expected exit 2 for missing gap ID"
    );
    assert!(
        stderr(&out).to_ascii_lowercase().contains("usage"),
        "expected usage in stderr, got {:?}",
        stderr(&out)
    );
}

#[test]
fn gap_show_unknown_id_exits_nonzero() {
    let dir = tempfile::tempdir().unwrap();
    setup_isolated_repo(dir.path());
    let out = run(dir.path(), &["gap", "show", "INFRA-9999999"]);
    assert!(!out.status.success(), "gap show unknown ID should fail");
}

// ── 5. gap ship ───────────────────────────────────────────────────────────────

#[test]
fn gap_ship_missing_id_exits_2() {
    let dir = tempfile::tempdir().unwrap();
    setup_isolated_repo(dir.path());
    let out = run(dir.path(), &["gap", "ship"]);
    assert_eq!(
        out.status.code(),
        Some(2),
        "expected exit 2 for missing gap ID"
    );
    assert!(
        stderr(&out).to_ascii_lowercase().contains("usage"),
        "expected usage in stderr, got {:?}",
        stderr(&out)
    );
}

#[test]
fn gap_ship_invalid_closed_pr_exits_2() {
    let dir = tempfile::tempdir().unwrap();
    setup_isolated_repo(dir.path());
    let id = reserve_gap(dir.path(), "INFRA", "test-ship-invalid");
    let out = run(
        dir.path(),
        &["gap", "ship", &id, "--closed-pr", "not-a-number"],
    );
    assert_eq!(
        out.status.code(),
        Some(2),
        "expected exit 2 for bad --closed-pr value"
    );
}

#[test]
fn gap_ship_reserved_gap_marks_done() {
    let dir = tempfile::tempdir().unwrap();
    setup_isolated_repo(dir.path());
    let id = reserve_gap(dir.path(), "INFRA", "test-ship-happy");
    let out = run(dir.path(), &["gap", "ship", &id, "--closed-pr", "9999"]);
    assert!(
        out.status.success(),
        "gap ship failed: {}\n{}",
        stdout(&out),
        stderr(&out)
    );
    // Verify via gap show --json that status is now "done".
    let show = run(dir.path(), &["gap", "show", &id, "--json"]);
    assert!(show.status.success(), "gap show after ship failed");
    let json: serde_json::Value = serde_json::from_str(stdout(&show).trim()).unwrap();
    assert_eq!(
        json["status"].as_str(),
        Some("done"),
        "gap status must be 'done' after ship"
    );
    assert_eq!(
        json["closed_pr"].as_i64(),
        Some(9999),
        "closed_pr must be 9999 after --closed-pr 9999"
    );
}

/// ZERO-WASTE-062: Regression test — gap-ship atomically updates BOTH state.db
/// AND docs/gaps/<ID>.yaml (status=done, closed_pr=N). Without this atomic
/// write, every shipped gap leaves state.db==done / yaml==open drift, requiring
/// a separate per-gap reconcile PR.
#[test]
fn gap_ship_updates_state_db_and_yaml_atomically() {
    let dir = tempfile::tempdir().unwrap();
    setup_isolated_repo(dir.path());
    let id = reserve_gap(dir.path(), "INFRA", "test-ship-yaml-atomic");

    // Ship the gap with a known closed_pr.
    let out = run(dir.path(), &["gap", "ship", &id, "--closed-pr", "4242"]);
    assert!(
        out.status.success(),
        "gap ship failed: {}\n{}",
        stdout(&out),
        stderr(&out)
    );

    // 1. Assert state.db shows status=done and closed_pr=4242.
    let show = run(dir.path(), &["gap", "show", &id, "--json"]);
    assert!(show.status.success(), "gap show after ship failed");
    let json: serde_json::Value = serde_json::from_str(stdout(&show).trim()).unwrap();
    assert_eq!(
        json["status"].as_str(),
        Some("done"),
        "state.db: gap status must be 'done' after ship"
    );
    assert_eq!(
        json["closed_pr"].as_i64(),
        Some(4242),
        "state.db: closed_pr must be 4242 after --closed-pr 4242"
    );

    // 2. Assert docs/gaps/<ID>.yaml exists with status=done and closed_pr=4242.
    let yaml_path = dir.path().join("docs/gaps").join(format!("{id}.yaml"));
    assert!(
        yaml_path.exists(),
        "docs/gaps/{id}.yaml must exist after gap ship (ZERO-WASTE-056)"
    );
    let yaml_content = std::fs::read_to_string(&yaml_path)
        .unwrap_or_else(|e| panic!("cannot read {}: {e}", yaml_path.display()));
    assert!(
        yaml_content.contains("status: done"),
        "docs/gaps/{id}.yaml must contain 'status: done', got:\n{yaml_content}"
    );
    assert!(
        yaml_content.contains("closed_pr: 4242"),
        "docs/gaps/{id}.yaml must contain 'closed_pr: 4242', got:\n{yaml_content}"
    );

    // 3. No test pollution — tempdir is cleaned up by tempfile::tempdir() Drop.
}

// ── 6. claim (top-level) ─────────────────────────────────────────────────────

#[test]
fn claim_no_args_exits_2() {
    let dir = tempfile::tempdir().unwrap();
    setup_isolated_repo(dir.path());
    let out = run(dir.path(), &["claim"]);
    assert_eq!(
        out.status.code(),
        Some(2),
        "expected exit 2 for `claim` with no gap ID"
    );
}

// ── 7. CREDIBLE-110: unknown subcommand must error, never hallucinate ───────

/// A single unknown token (`chump bogus`) must exit non-zero with a usage
/// error, not silently route to the model.
#[test]
fn unknown_subcommand_single_token_exits_nonzero_no_prose() {
    let dir = tempfile::tempdir().unwrap();
    setup_isolated_repo(dir.path());
    let out = run(dir.path(), &["bogus"]);
    assert_ne!(
        out.status.code(),
        Some(0),
        "unknown subcommand must not exit 0"
    );
    let err = stderr(&out);
    assert!(
        err.contains("unknown subcommand"),
        "stderr should report an unknown-subcommand error, got: {err}"
    );
    assert!(
        !stdout(&out).to_lowercase().contains("agriculture"),
        "must not hallucinate LLM prose for an unknown subcommand"
    );
}

/// CREDIBLE-110 regression: a *multi-word* unknown invocation (e.g. `chump
/// cron list`, mirroring the reported `chump farmer status` hallucination
/// before `farmer status` was wired up) must also error — previously only
/// the exact two-argv-element case (`args.len() == 2`) was caught, so any
/// unknown subcommand with trailing args silently dropped those args and
/// routed the first word alone to the model.
#[test]
fn unknown_subcommand_with_trailing_args_exits_nonzero_no_prose() {
    let dir = tempfile::tempdir().unwrap();
    setup_isolated_repo(dir.path());
    let out = run(dir.path(), &["cron", "list"]);
    assert_ne!(
        out.status.code(),
        Some(0),
        "unknown subcommand with trailing args must not exit 0"
    );
    let err = stderr(&out);
    assert!(
        err.contains("unknown subcommand"),
        "stderr should report an unknown-subcommand error, got: {err}"
    );
    assert!(
        stdout(&out).trim().is_empty(),
        "must not print a hallucinated reply to stdout, got: {}",
        stdout(&out)
    );
}
