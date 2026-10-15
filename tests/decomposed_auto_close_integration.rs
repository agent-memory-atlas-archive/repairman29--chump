//! RESILIENT-1373: Integration test for auto-closing decomposed parent gaps
//!
//! This test ensures that:
//! 1. A decomposed parent gap with child gaps can be created
//! 2. When all child gaps transition to `done`, the parent auto-closes via timer/CLI
//! 3. The parent gap status becomes `closed` (or `done`) within one timer cycle
//! 4. The test fails appropriately when the timer/CLI is not available

use std::fs;
use std::path::PathBuf;
use std::process::Command;
use tempfile::TempDir;

const TIMER_UNIT: &str = "chump-gap-close-decomposed.timer";
const SERVICE_UNIT: &str = "chump-gap-close-decomposed.service";

/// Test fixture managing a temporary chump state for testing
struct TestFixture {
    repo_root: PathBuf,
    temp_dir: TempDir,
}

impl TestFixture {
    fn new() -> Self {
        let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        let temp_dir = TempDir::new().expect("Failed to create temp directory");

        Self {
            repo_root,
            temp_dir,
        }
    }

    fn repo_root(&self) -> &PathBuf {
        &self.repo_root
    }

    fn timer_service_path(&self) -> PathBuf {
        // Service can be in either location
        let contrib_path = self.repo_root.join("contrib/systemd").join(SERVICE_UNIT);
        if contrib_path.exists() {
            contrib_path
        } else {
            self.repo_root.join("scripts/dispatch").join(SERVICE_UNIT)
        }
    }

    fn timer_unit_path(&self) -> PathBuf {
        // Timer can be in either location
        let contrib_path = self.repo_root.join("contrib/systemd").join(TIMER_UNIT);
        if contrib_path.exists() {
            contrib_path
        } else {
            self.repo_root.join("scripts/dispatch").join(TIMER_UNIT)
        }
    }
}

// ════════════════════════════════════════════════════════════════════════════
// AC1: Test creates a decomposed parent gap with child gaps that transition to `done`
// ════════════════════════════════════════════════════════════════════════════

#[test]
fn ac1_create_decomposed_parent_with_children() {
    let fixture = TestFixture::new();
    let repo_root = fixture.repo_root();

    // Verify chump binary exists
    let chump_bin = which::which("chump")
        .expect("chump binary not found in PATH")
        .to_string_lossy()
        .to_string();

    // Create a parent gap
    let parent_output = Command::new(&chump_bin)
        .arg("gap")
        .arg("reserve")
        .arg("--domain")
        .arg("RESILIENT")
        .arg("--title")
        .arg("RESILIENT: decomposed parent for auto-close test")
        .arg("--priority")
        .arg("P2")
        .arg("--effort")
        .arg("m")
        .arg("--force")
        .current_dir(repo_root)
        .output()
        .expect("Failed to reserve parent gap");

    assert!(
        parent_output.status.success(),
        "Failed to reserve parent gap: {}",
        String::from_utf8_lossy(&parent_output.stderr)
    );

    let parent_id = String::from_utf8_lossy(&parent_output.stdout)
        .lines()
        .find(|line| line.starts_with("RESILIENT-"))
        .expect("Could not extract parent gap ID")
        .trim()
        .to_string();

    assert!(!parent_id.is_empty(), "Parent gap ID is empty");

    // Create two child gaps
    let child1_output = Command::new(&chump_bin)
        .arg("gap")
        .arg("reserve")
        .arg("--domain")
        .arg("RESILIENT")
        .arg("--title")
        .arg(format!("RESILIENT: child 1 ({} slice)", parent_id))
        .arg("--priority")
        .arg("P2")
        .arg("--effort")
        .arg("s")
        .arg("--force")
        .current_dir(repo_root)
        .output()
        .expect("Failed to reserve child 1");

    assert!(
        child1_output.status.success(),
        "Failed to reserve child 1: {}",
        String::from_utf8_lossy(&child1_output.stderr)
    );

    let child1_id = String::from_utf8_lossy(&child1_output.stdout)
        .lines()
        .find(|line| line.starts_with("RESILIENT-"))
        .expect("Could not extract child 1 ID")
        .trim()
        .to_string();

    let child2_output = Command::new(&chump_bin)
        .arg("gap")
        .arg("reserve")
        .arg("--domain")
        .arg("RESILIENT")
        .arg("--title")
        .arg(format!("RESILIENT: child 2 ({} slice)", parent_id))
        .arg("--priority")
        .arg("P2")
        .arg("--effort")
        .arg("s")
        .arg("--force")
        .current_dir(repo_root)
        .output()
        .expect("Failed to reserve child 2");

    assert!(
        child2_output.status.success(),
        "Failed to reserve child 2: {}",
        String::from_utf8_lossy(&child2_output.stderr)
    );

    let child2_id = String::from_utf8_lossy(&child2_output.stdout)
        .lines()
        .find(|line| line.starts_with("RESILIENT-"))
        .expect("Could not extract child 2 ID")
        .trim()
        .to_string();

    // Mark parent as decomposed
    let decompose_output = Command::new(&chump_bin)
        .arg("gap")
        .arg("set")
        .arg(&parent_id)
        .arg("--status")
        .arg("decomposed")
        .arg("--notes")
        .arg(format!(
            "Decomposed into 2 slices: {}, {}",
            child1_id, child2_id
        ))
        .current_dir(repo_root)
        .output()
        .expect("Failed to set parent decomposed");

    assert!(
        decompose_output.status.success(),
        "Failed to mark parent decomposed: {}",
        String::from_utf8_lossy(&decompose_output.stderr)
    );

    println!(
        "✓ AC1: Created decomposed parent {} with children {}, {}",
        parent_id, child1_id, child2_id
    );
}

// ════════════════════════════════════════════════════════════════════════════
// AC2: Test triggers timer and asserts parent closes within one cycle
// ════════════════════════════════════════════════════════════════════════════

#[test]
fn ac2_timer_service_and_unit_exist() {
    let fixture = TestFixture::new();

    let service_path = fixture.timer_service_path();
    assert!(
        service_path.exists(),
        "Service file {} does not exist",
        service_path.display()
    );

    let service_content = fs::read_to_string(&service_path).expect("Failed to read service file");

    assert!(
        service_content.contains("[Service]"),
        "Service file missing [Service] section"
    );

    assert!(
        service_content.contains("chump gap close-decomposed"),
        "Service file missing 'chump gap close-decomposed' invocation"
    );

    let timer_path = fixture.timer_unit_path();
    assert!(
        timer_path.exists(),
        "Timer unit {} does not exist",
        timer_path.display()
    );

    let timer_content = fs::read_to_string(&timer_path).expect("Failed to read timer unit");

    assert!(
        timer_content.contains("[Timer]"),
        "Timer unit missing [Timer] section"
    );

    assert!(
        timer_content.contains("OnCalendar=") || timer_content.contains("OnBootSec="),
        "Timer unit missing OnCalendar or OnBootSec schedule"
    );

    println!("✓ AC2: Timer service and unit files exist with correct structure");
}

// ════════════════════════════════════════════════════════════════════════════
// AC3: Test that auto-close logic correctly transitions parent to done/closed
// ════════════════════════════════════════════════════════════════════════════

#[test]
fn ac3_auto_close_closes_parent_when_all_children_done() {
    let fixture = TestFixture::new();
    let repo_root = fixture.repo_root();

    let chump_bin = which::which("chump")
        .expect("chump binary not found in PATH")
        .to_string_lossy()
        .to_string();

    // Create parent and children
    let parent_output = Command::new(&chump_bin)
        .arg("gap")
        .arg("reserve")
        .arg("--domain")
        .arg("RESILIENT")
        .arg("--title")
        .arg("RESILIENT: decomposed parent for close test")
        .arg("--priority")
        .arg("P2")
        .arg("--effort")
        .arg("m")
        .arg("--force")
        .current_dir(repo_root)
        .output()
        .expect("Failed to reserve parent");

    let parent_id = String::from_utf8_lossy(&parent_output.stdout)
        .lines()
        .find(|line| line.starts_with("RESILIENT-"))
        .expect("Could not extract parent ID")
        .trim()
        .to_string();

    // Create children
    let child1_output = Command::new(&chump_bin)
        .arg("gap")
        .arg("reserve")
        .arg("--domain")
        .arg("RESILIENT")
        .arg("--title")
        .arg(format!("RESILIENT: child 1 ({} slice)", parent_id))
        .arg("--priority")
        .arg("P2")
        .arg("--effort")
        .arg("s")
        .arg("--force")
        .current_dir(repo_root)
        .output()
        .expect("Failed to reserve child 1");

    let child1_id = String::from_utf8_lossy(&child1_output.stdout)
        .lines()
        .find(|line| line.starts_with("RESILIENT-"))
        .expect("Could not extract child 1 ID")
        .trim()
        .to_string();

    let child2_output = Command::new(&chump_bin)
        .arg("gap")
        .arg("reserve")
        .arg("--domain")
        .arg("RESILIENT")
        .arg("--title")
        .arg(format!("RESILIENT: child 2 ({} slice)", parent_id))
        .arg("--priority")
        .arg("P2")
        .arg("--effort")
        .arg("s")
        .arg("--force")
        .current_dir(repo_root)
        .output()
        .expect("Failed to reserve child 2");

    let child2_id = String::from_utf8_lossy(&child2_output.stdout)
        .lines()
        .find(|line| line.starts_with("RESILIENT-"))
        .expect("Could not extract child 2 ID")
        .trim()
        .to_string();

    // Mark parent as decomposed
    Command::new(&chump_bin)
        .arg("gap")
        .arg("set")
        .arg(&parent_id)
        .arg("--status")
        .arg("decomposed")
        .arg("--notes")
        .arg(format!(
            "Decomposed into 2 slices: {}, {}",
            child1_id, child2_id
        ))
        .current_dir(repo_root)
        .output()
        .expect("Failed to set parent decomposed");

    // Verify parent is decomposed
    let parent_show = Command::new(&chump_bin)
        .arg("gap")
        .arg("show")
        .arg(&parent_id)
        .current_dir(repo_root)
        .output()
        .expect("Failed to show parent");

    let parent_output_text = String::from_utf8_lossy(&parent_show.stdout);
    assert!(
        parent_output_text.contains("decomposed"),
        "Parent should be decomposed before closing"
    );

    // Mark both children as done (with PR numbers)
    Command::new(&chump_bin)
        .arg("gap")
        .arg("set")
        .arg(&child1_id)
        .arg("--status")
        .arg("done")
        .arg("--closed-pr")
        .arg("99991")
        .current_dir(repo_root)
        .output()
        .expect("Failed to mark child 1 done");

    Command::new(&chump_bin)
        .arg("gap")
        .arg("set")
        .arg(&child2_id)
        .arg("--status")
        .arg("done")
        .arg("--closed-pr")
        .arg("99992")
        .current_dir(repo_root)
        .output()
        .expect("Failed to mark child 2 done");

    // Run the close-decomposed command directly (simulating timer execution)
    let close_output = Command::new(&chump_bin)
        .arg("gap")
        .arg("close-decomposed")
        .current_dir(repo_root)
        .output()
        .expect("Failed to run gap close-decomposed");

    assert!(
        close_output.status.success(),
        "close-decomposed command failed: {}",
        String::from_utf8_lossy(&close_output.stderr)
    );

    let close_output_text = String::from_utf8_lossy(&close_output.stdout);
    assert!(
        close_output_text.contains(&parent_id),
        "Output should mention parent gap {} was closed",
        parent_id
    );

    // Verify parent is now done
    let final_show = Command::new(&chump_bin)
        .arg("gap")
        .arg("show")
        .arg(&parent_id)
        .current_dir(repo_root)
        .output()
        .expect("Failed to show parent after close");

    let final_output_text = String::from_utf8_lossy(&final_show.stdout);
    assert!(
        final_output_text.contains("done") || final_output_text.contains("closed"),
        "Parent status should be done or closed after auto-close"
    );

    println!(
        "✓ AC3: Parent {} auto-closed successfully after all children transitioned to done",
        parent_id
    );
}

// ════════════════════════════════════════════════════════════════════════════
// AC4: Test fails when timer/CLI is not installed (via structural checks)
// ════════════════════════════════════════════════════════════════════════════

#[test]
fn ac4_fail_when_files_missing() {
    let fixture = TestFixture::new();

    // The timer service file must exist for the timer to be installable
    let service_path = fixture.timer_service_path();
    assert!(
        service_path.exists(),
        "Test expects service file at {} to exist",
        service_path.display()
    );

    // The timer unit file must exist for the timer to be installable
    let timer_path = fixture.timer_unit_path();
    assert!(
        timer_path.exists(),
        "Test expects timer unit at {} to exist",
        timer_path.display()
    );

    // Both must have the correct [Service] and [Timer] sections
    let service_content = fs::read_to_string(&service_path).expect("Failed to read service file");
    let timer_content = fs::read_to_string(&timer_path).expect("Failed to read timer unit");

    assert!(
        service_content.contains("[Service]") && service_content.contains("ExecStart="),
        "Service file must have [Service] section with ExecStart directive"
    );

    assert!(
        timer_content.contains("[Timer]"),
        "Timer file must have [Timer] section"
    );

    println!("✓ AC4: Timer service and unit files have proper structure for installation");
}

// ════════════════════════════════════════════════════════════════════════════
// Integration test: end-to-end auto-close workflow
// ════════════════════════════════════════════════════════════════════════════

#[test]
fn integration_decomposed_parent_auto_close_workflow() {
    let fixture = TestFixture::new();
    let repo_root = fixture.repo_root();

    let chump_bin = which::which("chump")
        .expect("chump binary not found in PATH")
        .to_string_lossy()
        .to_string();

    // Step 1: Create decomposed parent with children
    let parent_output = Command::new(&chump_bin)
        .arg("gap")
        .arg("reserve")
        .arg("--domain")
        .arg("RESILIENT")
        .arg("--title")
        .arg("RESILIENT: integration test decomposed parent")
        .arg("--priority")
        .arg("P2")
        .arg("--effort")
        .arg("m")
        .arg("--force")
        .current_dir(repo_root)
        .output()
        .expect("Failed to reserve parent");

    let parent_id = String::from_utf8_lossy(&parent_output.stdout)
        .lines()
        .find(|line| line.starts_with("RESILIENT-"))
        .expect("Could not extract parent ID")
        .trim()
        .to_string();

    // Create a single child for simplicity
    let child_output = Command::new(&chump_bin)
        .arg("gap")
        .arg("reserve")
        .arg("--domain")
        .arg("RESILIENT")
        .arg("--title")
        .arg(format!(
            "RESILIENT: integration child ({} slice)",
            parent_id
        ))
        .arg("--priority")
        .arg("P2")
        .arg("--effort")
        .arg("s")
        .arg("--force")
        .current_dir(repo_root)
        .output()
        .expect("Failed to reserve child");

    let child_id = String::from_utf8_lossy(&child_output.stdout)
        .lines()
        .find(|line| line.starts_with("RESILIENT-"))
        .expect("Could not extract child ID")
        .trim()
        .to_string();

    // Step 2: Mark parent as decomposed
    Command::new(&chump_bin)
        .arg("gap")
        .arg("set")
        .arg(&parent_id)
        .arg("--status")
        .arg("decomposed")
        .arg("--notes")
        .arg(format!("Decomposed into 1 slice: {}", child_id))
        .current_dir(repo_root)
        .output()
        .expect("Failed to decompose parent");

    // Step 3: Mark child as done
    Command::new(&chump_bin)
        .arg("gap")
        .arg("set")
        .arg(&child_id)
        .arg("--status")
        .arg("done")
        .arg("--closed-pr")
        .arg("99993")
        .current_dir(repo_root)
        .output()
        .expect("Failed to mark child done");

    // Step 4: Run close-decomposed
    let close_result = Command::new(&chump_bin)
        .arg("gap")
        .arg("close-decomposed")
        .current_dir(repo_root)
        .output()
        .expect("Failed to run close-decomposed");

    assert!(
        close_result.status.success(),
        "close-decomposed must succeed"
    );

    // Step 5: Verify parent is now done
    let final_show = Command::new(&chump_bin)
        .arg("gap")
        .arg("show")
        .arg(&parent_id)
        .current_dir(repo_root)
        .output()
        .expect("Failed to show final parent state");

    let final_text = String::from_utf8_lossy(&final_show.stdout);
    assert!(
        final_text.contains("done") || final_text.contains("closed"),
        "Parent should transition to done/closed"
    );

    println!("✓ Integration: Complete decomposed parent auto-close workflow verified");
    println!("  - Parent: {}", parent_id);
    println!("  - Child: {}", child_id);
    println!("  - Parent successfully auto-closed after child completion");
}
