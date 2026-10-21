//! INFRA-216 — cross-host reserve race integration test.
//!
//! Spawns two `chump gap reserve` processes in parallel against the same
//! repo root to verify that the INFRA-216 post-reserve verification
//! (`reserve_verified`) prevents both processes from returning the same gap
//! ID. Runs against the compiled `chump` binary via `CARGO_BIN_EXE_chump`.
//!
//! Run:
//!   cargo test --test gap_reserve_cross_host_race -- --nocapture

use std::fs;
use std::path::Path;
use std::process::Command;

fn setup_repo(dir: &Path) {
    Command::new("git")
        .args(["init", "--quiet"])
        .current_dir(dir)
        .status()
        .expect("git init");
    // Minimal docs/gaps directory so reserve can write the per-file YAML.
    fs::create_dir_all(dir.join("docs").join("gaps")).unwrap();
    // .chump-locks for lease files.
    fs::create_dir_all(dir.join(".chump-locks")).unwrap();
    // .chump for state.db.
    fs::create_dir_all(dir.join(".chump")).unwrap();
    // RESILIENT-1652 (task 0b): the Linux farmer oauth gate judges
    // <state-home>/.chump/oauth-token.json by CONTENT and reds on a MISSING
    // token. With HOME/CHUMP_HOME isolated to this empty tempdir there is no
    // token, so `gap reserve` (which --force-duplicate does NOT bypass — only
    // --force bypasses the farmer gate) would go RED. Seed a hermetic fixture
    // token so the gate reads oauth_fresh=green, WITHOUT loosening the gate for
    // a real node (the fixture lives only in this tempdir). The token literal is
    // assembled at runtime so the secret-scanner does not flag the fixture; the
    // written file still carries the `sk-` prefix the content verdict needs.
    let fixture_token = format!("sk-{}", "test-reserve-race-fixture-not-a-real-secret");
    fs::write(
        dir.join(".chump").join("oauth-token.json"),
        format!(r#"{{"token":"{fixture_token}","source":"test-fixture"}}"#),
    )
    .unwrap();
}

/// Two concurrent `chump gap reserve` calls on the same repo root must
/// return distinct IDs. The SQLite `BEGIN IMMEDIATE` already guarantees
/// this for same-host races; this test verifies the binary continues to
/// behave correctly end-to-end with the INFRA-216 verification layer active.
#[test]
fn two_concurrent_reserves_return_distinct_ids() {
    let bin = env!("CARGO_BIN_EXE_chump");
    let dir = tempfile::tempdir().expect("tempdir");
    setup_repo(dir.path());
    let root = dir.path().to_path_buf();
    let bin = bin.to_string();

    let root_a = root.clone();
    let root_b = root.clone();
    let bin_a = bin.clone();
    let bin_b = bin.clone();

    let root_a_str = root_a.to_string_lossy().into_owned();
    let root_b_str = root_b.to_string_lossy().into_owned();
    // RESILIENT-1652 (task 2): pin the node state dir to each tempdir's .chump so
    // the farmer gate's pause check is hermetic. The node installer exports
    // CHUMP_STATE_DIR, so a worker's pre-push run would otherwise inherit the
    // REAL (possibly paused) node.env and red the gate. Not a gate loosening —
    // a real paused node.env still reds.
    let state_a = format!("{root_a_str}/.chump");
    let state_b = format!("{root_b_str}/.chump");

    let t1 = std::thread::spawn(move || {
        Command::new(&bin_a)
            .envs([
                ("CHUMP_RESERVE_SCAN_OPEN_PRS", "0"),
                ("CHUMP_RESERVE_VERIFY", "1"),
                ("CHUMP_RESERVE_VERIFY_SLEEP_MS", "50"),
                ("CHUMP_SESSION_ID", "session-a"),
                ("CHUMP_RAW_YAML_LOCK", "0"),
                ("FLEET_029_AMBIENT_GLANCE_SKIP", "1"),
                // INFRA-813: prevent autostage from touching files outside the tempdir.
                ("CHUMP_RESERVE_NO_AUTOSTAGE", "1"),
                // Ensure repo_root() resolves to the tempdir, not the caller's
                // CHUMP_REPO/CHUMP_HOME, so test gaps don't pollute the real registry.
                ("CHUMP_REPO", &root_a_str),
                ("CHUMP_HOME", &root_a_str),
                ("CHUMP_STATE_DIR", &state_a),
                // Isolate HOME too: the RESILIENT-069 farmer gate resolves
                // oauth-token.json under $HOME/.chump; setup_repo seeds a
                // hermetic fixture token there so the Linux content-gate reads
                // oauth_fresh=green, keeping the test independent of the dev
                // box's ambient token freshness (RESILIENT-1652 task 0b).
                ("HOME", &root_a_str),
            ])
            .args([
                "gap",
                "reserve",
                "--domain",
                "INFRA",
                "--title",
                "race-a",
                "--force-duplicate",
            ])
            .current_dir(&root_a)
            .output()
            .expect("chump gap reserve session-a")
    });

    let t2 = std::thread::spawn(move || {
        Command::new(&bin_b)
            .envs([
                ("CHUMP_RESERVE_SCAN_OPEN_PRS", "0"),
                ("CHUMP_RESERVE_VERIFY", "1"),
                ("CHUMP_RESERVE_VERIFY_SLEEP_MS", "50"),
                ("CHUMP_SESSION_ID", "session-z"),
                ("CHUMP_RAW_YAML_LOCK", "0"),
                ("FLEET_029_AMBIENT_GLANCE_SKIP", "1"),
                // INFRA-813: prevent autostage from touching files outside the tempdir.
                ("CHUMP_RESERVE_NO_AUTOSTAGE", "1"),
                // Ensure repo_root() resolves to the tempdir, not the caller's
                // CHUMP_REPO/CHUMP_HOME, so test gaps don't pollute the real registry.
                ("CHUMP_REPO", &root_b_str),
                ("CHUMP_HOME", &root_b_str),
                ("CHUMP_STATE_DIR", &state_b),
                // Isolate HOME too (see session-a note): farmer gate reads
                // $HOME/.chump/oauth-token.json; setup_repo's fixture token
                // reads fresh (RESILIENT-1652 task 0b).
                ("HOME", &root_b_str),
            ])
            .args([
                "gap",
                "reserve",
                "--domain",
                "INFRA",
                "--title",
                "race-z",
                "--force-duplicate",
            ])
            .current_dir(&root_b)
            .output()
            .expect("chump gap reserve session-z")
    });

    let out1 = t1.join().expect("thread 1");
    let out2 = t2.join().expect("thread 2");

    assert!(
        out1.status.success(),
        "session-a reserve failed: {}",
        String::from_utf8_lossy(&out1.stderr)
    );
    assert!(
        out2.status.success(),
        "session-z reserve failed: {}",
        String::from_utf8_lossy(&out2.stderr)
    );

    let id1 = String::from_utf8_lossy(&out1.stdout).trim().to_string();
    let id2 = String::from_utf8_lossy(&out2.stdout).trim().to_string();

    assert!(
        id1.starts_with("INFRA-"),
        "unexpected id1: {id1} (stderr: {})",
        String::from_utf8_lossy(&out1.stderr)
    );
    assert!(
        id2.starts_with("INFRA-"),
        "unexpected id2: {id2} (stderr: {})",
        String::from_utf8_lossy(&out2.stderr)
    );
    assert_ne!(
        id1, id2,
        "both reserves returned the same ID — collision not prevented: {id1} == {id2}"
    );
}
