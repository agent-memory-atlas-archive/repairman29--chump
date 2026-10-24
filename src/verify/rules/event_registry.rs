//! Rule: event-registry — ambient event kinds and their registry entries
//! must land PAIRED, in both directions, diff-scoped:
//!
//!   direction 1 (emit-without-register): a new kind literal added in a
//!   production path must be registered in
//!   docs/observability/EVENT_REGISTRY.yaml (working tree — registering in
//!   the same commit satisfies the rule) or reserved in
//!   scripts/ci/event-registry-reserved.txt.
//!
//!   direction 2 (register-without-emit): a registry entry added in this
//!   diff must be paired with an emit literal or scanner-anchor comment in
//!   the same diff, an existing emit site in the tree, or a reserved.txt
//!   entry.
//!
//! Ported from scripts/git-hooks/pre-commit-event-registry.sh (INFRA-754,
//! direction 1) in the INFRA-1237/INFRA-1287 refined form: the scan is
//! limited to the production paths the CI coverage gate audits, so test
//! fixtures under scripts/ci/ and doc examples never false-positive the way
//! the staged-diff shell gate could. The repo-wide CI audit
//! (scripts/ci/test-event-registry-coverage.sh) stays in place
//! (parallel-run); the effect_metric completeness companion (INFRA-1517)
//! stays in its shell hook — it checks registry-entry fields, not pairing.
//!
//! NOTE: kind-literal needles below are built at runtime from fragments so
//! this file never contains a contiguous kind-literal — the rule (and the
//! legacy gates) must not flag their own machinery.

use super::{Evaluation, Rule};
use crate::verify::{ChangeKind, VerifyContext};
use std::collections::BTreeSet;
use std::path::Path;

pub struct EventRegistry;

const RULE_ID: &str = "event-registry";

const RECEIPT: &str = "INFRA-754/INFRA-1237/INFRA-1287: EVENT_REGISTRY.yaml is the ground-truth contract every ambient consumer (fleet-brief, waste-tally, kpi-report, watchdogs) reads; emit-without-register makes consumers silently drop events and under-report SLOs, register-without-emit left 88 orphan entries whose dashboards displayed empty rows the operator could not interpret";

const REGISTRY_REL: &str = "docs/observability/EVENT_REGISTRY.yaml";
const RESERVED_REL: &str = "scripts/ci/event-registry-reserved.txt";
/// RESILIENT-1618: new kinds land as per-kind fragments under this directory
/// instead of editing the frozen monolith (new files never collide on GitHub's
/// server-side merge). The canonical registry every consumer reads
/// (scripts/ci/gen-registries.sh) is the monolith base PLUS these fragments, so
/// this gate must aggregate them too — otherwise a commit that registers a kind
/// via a fragment (the supported path) false-fails emit-without-register.
const EVENTS_FRAGMENT_DIR_REL: &str = "docs/observability/events.d";

/// Production paths audited by the CI coverage gate (INFRA-1287 set).
/// scripts/ci/, scripts/git-hooks/, scripts/ab-harness/, scripts/auto-docs/
/// legitimately mention kind literals as fixtures/templates and are excluded.
const PROD_PATHS: &[&str] = &[
    "src/",
    "crates/",
    "scripts/coord/",
    "scripts/dispatch/",
    "scripts/ops/",
    "scripts/dev/",
    "scripts/setup/",
    "scripts/content-bots/",
    "scripts/arsenal/",
    "scripts/chairman/",
];

const CODE_EXTS: &[&str] = &["rs", "sh", "py", "ts", "tsx", "js", "yml", "yaml"];

/// This rule's own source — self-exemption, like no-new-bypass-env-vars.
const EXEMPT_PATHS: &[&str] = &["src/verify/rules/event_registry.rs"];

impl Rule for EventRegistry {
    fn id(&self) -> &'static str {
        RULE_ID
    }

    fn incident_receipt(&self) -> &'static str {
        RECEIPT
    }

    fn evaluate(&self, ctx: &VerifyContext) -> Evaluation {
        let registry_path = ctx.repo_root.join(REGISTRY_REL);
        let Ok(registry_body) = std::fs::read_to_string(&registry_path) else {
            // Mirrors the legacy gate: on a tree without the registry
            // (fixture repos, pre-INFRA-754 branches) the gate is silent.
            return Evaluation::NotApplicable(format!("{REGISTRY_REL} not present"));
        };

        // Emit literals added in this diff, in production paths.
        let mut emitted_in_diff: BTreeSet<String> = BTreeSet::new();
        for f in &ctx.files {
            if f.kind == ChangeKind::Deleted
                || !is_prod_code_path(&f.path)
                || EXEMPT_PATHS.contains(&f.path.as_str())
            {
                continue;
            }
            for line in &f.added_lines {
                for k in extract_kind_literals(line) {
                    emitted_in_diff.insert(k);
                }
            }
        }

        // Registry entries added in this diff.
        let mut registered_in_diff: BTreeSet<String> = BTreeSet::new();
        for f in &ctx.files {
            if f.path == REGISTRY_REL && f.kind != ChangeKind::Deleted {
                for line in &f.added_lines {
                    if let Some(k) = parse_registry_entry_line(line) {
                        registered_in_diff.insert(k);
                    }
                }
            }
        }

        if emitted_in_diff.is_empty() && registered_in_diff.is_empty() {
            return Evaluation::NotApplicable(
                "no new kind literals or registry entries in diff".to_string(),
            );
        }

        let registered: BTreeSet<String> = load_registered(&ctx.repo_root, &registry_body);
        let reserved = load_reserved(ctx);

        // Direction 1: emit-without-register.
        let unregistered: Vec<&String> = emitted_in_diff
            .iter()
            .filter(|k| !registered.contains(*k) && !reserved.contains(*k))
            .collect();

        // Direction 2: register-without-emit, for entries ADDED here.
        let orphaned: Vec<&String> = registered_in_diff
            .iter()
            .filter(|k| {
                !emitted_in_diff.contains(*k)
                    && !reserved.contains(*k)
                    && !repo_has_emit(&ctx.repo_root, k)
            })
            .collect();

        if unregistered.is_empty() && orphaned.is_empty() {
            return Evaluation::Pass(format!(
                "{} emit(s) registered/reserved, {} registry addition(s) paired",
                emitted_in_diff.len(),
                registered_in_diff.len()
            ));
        }

        let mut parts = Vec::new();
        let mut fixes = Vec::new();
        if !unregistered.is_empty() {
            parts.push(format!(
                "emit-without-register: {}",
                unregistered
                    .iter()
                    .map(|s| s.as_str())
                    .collect::<Vec<_>>()
                    .join(", ")
            ));
            fixes.push(format!(
                "register each emitted kind in {REGISTRY_REL} (- kind: <name> / emitter / trigger; effect_metric per INFRA-1517), reuse an existing kind, or add it to {RESERVED_REL} with a '# reason:' comment"
            ));
        }
        if !orphaned.is_empty() {
            parts.push(format!(
                "register-without-emit: {}",
                orphaned
                    .iter()
                    .map(|s| s.as_str())
                    .collect::<Vec<_>>()
                    .join(", ")
            ));
            fixes.push(format!(
                "pair each new registry entry with its emit site in the same change (a scanner-anchor comment at the emit site counts), or add the kind to {RESERVED_REL} with a '# reason:' comment while the emitter is WIP"
            ));
        }

        Evaluation::Fail {
            detail: parts.join(" ; "),
            remediation: fixes.join(" ; "),
        }
    }
}

fn is_prod_code_path(path: &str) -> bool {
    if !PROD_PATHS.iter().any(|p| path.starts_with(p)) {
        return false;
    }
    match path.rsplit_once('.') {
        Some((_, ext)) => CODE_EXTS.contains(&ext),
        None => false,
    }
}

/// The `"kind"` needle, built from fragments so this source never contains
/// a contiguous kind-literal.
fn kind_needle() -> String {
    format!("\"{}{}\"", "ki", "nd")
}

/// Extract kind-literal values from one line: `"kind" : "<ident>"` with
/// optional whitespace around the colon — same shape the legacy gate's
/// regex matched, parsed instead of grepped.
pub(crate) fn extract_kind_literals(line: &str) -> Vec<String> {
    let needle = kind_needle();
    let mut out = Vec::new();
    let mut from = 0usize;
    while let Some(rel) = line[from..].find(&needle) {
        let mut rest = line[from + rel + needle.len()..].trim_start();
        from += rel + needle.len();
        if !rest.starts_with(':') {
            continue;
        }
        rest = rest[1..].trim_start();
        let Some(stripped) = rest.strip_prefix('"') else {
            continue;
        };
        let ident: String = stripped
            .chars()
            .take_while(|c| c.is_ascii_alphanumeric() || *c == '_')
            .collect();
        if ident.is_empty()
            || !stripped[ident.len()..].starts_with('"')
            || !ident
                .chars()
                .next()
                .is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
        {
            continue;
        }
        out.push(ident);
    }
    out
}

/// Parse a registry entry line: `- kind: <name>` (leading whitespace
/// tolerated, matching the CI coverage gate's parse).
pub(crate) fn parse_registry_entry_line(line: &str) -> Option<String> {
    let t = line.trim_start();
    let rest = t.strip_prefix("- ")?.trim_start();
    let rest = rest.strip_prefix("ki")?.strip_prefix("nd")?.trim_start();
    let rest = rest.strip_prefix(':')?.trim();
    let name: String = rest
        .chars()
        .take_while(|c| c.is_ascii_alphanumeric() || *c == '_')
        .collect();
    if name.is_empty() || name.len() != rest.split_whitespace().next().unwrap_or("").len() {
        return None;
    }
    Some(name)
}

/// Collect every registered kind from the canonical registry view: the frozen
/// monolith base plus each per-kind fragment under events.d/ (RESILIENT-1618).
/// Mirrors scripts/ci/gen-registries.sh so this gate and the CI coverage gate
/// agree on what "registered" means.
fn load_registered(repo_root: &Path, monolith_body: &str) -> BTreeSet<String> {
    let mut registered: BTreeSet<String> = monolith_body
        .lines()
        .filter_map(parse_registry_entry_line)
        .collect();
    if let Ok(entries) = std::fs::read_dir(repo_root.join(EVENTS_FRAGMENT_DIR_REL)) {
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("yaml") {
                continue;
            }
            if let Ok(body) = std::fs::read_to_string(&path) {
                for k in body.lines().filter_map(parse_registry_entry_line) {
                    registered.insert(k);
                }
            }
        }
    }
    registered
}

fn load_reserved(ctx: &VerifyContext) -> BTreeSet<String> {
    let Ok(body) = std::fs::read_to_string(ctx.repo_root.join(RESERVED_REL)) else {
        return BTreeSet::new();
    };
    body.lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .filter_map(|l| l.split_whitespace().next().map(str::to_string))
        .collect()
}

/// Does any production-path file in the tree already emit this kind?
/// (Registering a previously-unregistered kind that is already emitted is a
/// legitimate reconciliation commit — direction 2 must not block it.)
fn repo_has_emit(repo_root: &Path, kind: &str) -> bool {
    PROD_PATHS
        .iter()
        .any(|prod| dir_has_emit(&repo_root.join(prod.trim_end_matches('/')), kind))
}

fn dir_has_emit(dir: &Path, kind: &str) -> bool {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return false;
    };
    let needle = kind_needle();
    for entry in entries.flatten() {
        let path = entry.path();
        let name = entry.file_name().to_string_lossy().to_string();
        if path.is_dir() {
            if name == "target" || name.starts_with('.') {
                continue;
            }
            if dir_has_emit(&path, kind) {
                return true;
            }
            continue;
        }
        let ext_ok = path
            .extension()
            .and_then(|e| e.to_str())
            .is_some_and(|e| CODE_EXTS.contains(&e));
        if !ext_ok {
            continue;
        }
        if let Ok(body) = std::fs::read_to_string(&path) {
            // Cheap substring pre-filter, then the parsed extractor for the
            // authoritative match (handles whitespace around the colon).
            if body.contains(&needle)
                && body
                    .lines()
                    .any(|l| extract_kind_literals(l).iter().any(|k| k == kind))
            {
                return true;
            }
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::verify::{test_context, DiffFile, Stage};
    use std::path::PathBuf;

    /// Build an emit line without a contiguous kind-literal in THIS source.
    fn emit_line(kind: &str) -> String {
        format!("printf '{{{}:\"{kind}\"}}' >> log", kind_needle())
    }

    /// Build a registry entry line the same way.
    fn entry_line(kind: &str) -> String {
        format!("  - {}{}: {kind}", "ki", "nd")
    }

    fn fixture_root(tag: &str, registered: &[&str], reserved: &[&str]) -> PathBuf {
        let tmp = std::env::temp_dir().join(format!(
            "verify-event-registry-{tag}-{}",
            std::process::id()
        ));
        let obs = tmp.join("docs/observability");
        let ci = tmp.join("scripts/ci");
        std::fs::create_dir_all(&obs).unwrap();
        std::fs::create_dir_all(&ci).unwrap();
        let mut reg = String::from("# registry\nevents:\n");
        for k in registered {
            reg.push_str(&entry_line(k));
            reg.push('\n');
        }
        std::fs::write(obs.join("EVENT_REGISTRY.yaml"), reg).unwrap();
        let mut res = String::from("# reserved\n");
        for k in reserved {
            res.push_str(k);
            res.push('\n');
        }
        std::fs::write(ci.join("event-registry-reserved.txt"), res).unwrap();
        tmp
    }

    fn file(path: &str, kind: ChangeKind, added: Vec<String>) -> DiffFile {
        DiffFile {
            path: path.to_string(),
            kind,
            added_lines: added,
        }
    }

    fn eval_with(root: &Path, files: Vec<DiffFile>) -> Evaluation {
        let ctx = test_context(Stage::CommitMsg, root, files, Some("msg"), None);
        EventRegistry.evaluate(&ctx)
    }

    #[test]
    fn missing_registry_is_not_applicable() {
        let ev = eval_with(
            Path::new("/nonexistent-chump-fixture"),
            vec![file(
                "scripts/coord/x.sh",
                ChangeKind::Modified,
                vec![emit_line("anything_goes")],
            )],
        );
        assert!(matches!(ev, Evaluation::NotApplicable(_)));
    }

    #[test]
    fn registered_emit_passes() {
        let root = fixture_root("registered", &["fixture_alpha"], &[]);
        let ev = eval_with(
            &root,
            vec![file(
                "src/thing.rs",
                ChangeKind::Modified,
                vec![emit_line("fixture_alpha")],
            )],
        );
        assert!(matches!(ev, Evaluation::Pass(_)));
    }

    #[test]
    fn unregistered_emit_fails_with_registry_remediation() {
        let root = fixture_root("unregistered", &["fixture_alpha"], &[]);
        let ev = eval_with(
            &root,
            vec![file(
                "scripts/dispatch/x.sh",
                ChangeKind::Modified,
                vec![emit_line("fixture_rogue")],
            )],
        );
        match ev {
            Evaluation::Fail {
                detail,
                remediation,
            } => {
                assert!(detail.contains("fixture_rogue"), "{detail}");
                assert!(remediation.contains("EVENT_REGISTRY.yaml"), "{remediation}");
            }
            _ => panic!("expected fail"),
        }
    }

    #[test]
    fn fragment_registered_emit_passes() {
        // RESILIENT-1618: a kind registered via a per-kind events.d/ fragment
        // (not the monolith base) must still count as registered — this is the
        // supported path for new kinds and must not false-fail the gate.
        let root = fixture_root("fragment", &[], &[]);
        let frag_dir = root.join("docs/observability/events.d");
        std::fs::create_dir_all(&frag_dir).unwrap();
        std::fs::write(
            frag_dir.join("fixture_fragment.yaml"),
            format!("{}\n", entry_line("fixture_fragment")),
        )
        .unwrap();
        let ev = eval_with(
            &root,
            vec![file(
                "scripts/dispatch/x.sh",
                ChangeKind::Added,
                vec![emit_line("fixture_fragment")],
            )],
        );
        assert!(
            matches!(ev, Evaluation::Pass(_)),
            "fragment-registered emit should pass"
        );
    }

    #[test]
    fn reserved_emit_passes() {
        let root = fixture_root("reserved", &[], &["fixture_reserved"]);
        let ev = eval_with(
            &root,
            vec![file(
                "src/thing.rs",
                ChangeKind::Modified,
                vec![emit_line("fixture_reserved")],
            )],
        );
        assert!(matches!(ev, Evaluation::Pass(_)));
    }

    #[test]
    fn non_prod_paths_are_ignored() {
        let root = fixture_root("nonprod", &[], &[]);
        let ev = eval_with(
            &root,
            vec![
                file(
                    "scripts/ci/test-fixture.sh",
                    ChangeKind::Added,
                    vec![emit_line("fixture_in_test")],
                ),
                file(
                    "docs/process/EXAMPLES.md",
                    ChangeKind::Modified,
                    vec![emit_line("fixture_in_doc")],
                ),
            ],
        );
        assert!(matches!(ev, Evaluation::NotApplicable(_)));
    }

    #[test]
    fn registry_entry_paired_with_diff_emit_passes() {
        let root = fixture_root("paired", &["fixture_new"], &[]);
        let ev = eval_with(
            &root,
            vec![
                file(
                    "docs/observability/EVENT_REGISTRY.yaml",
                    ChangeKind::Modified,
                    vec![entry_line("fixture_new")],
                ),
                file(
                    "scripts/coord/y.sh",
                    ChangeKind::Modified,
                    vec![emit_line("fixture_new")],
                ),
            ],
        );
        assert!(
            matches!(ev, Evaluation::Pass(_)),
            "paired entry should pass"
        );
    }

    #[test]
    fn orphan_registry_entry_fails_with_anchor_remediation() {
        let root = fixture_root("orphan", &["fixture_orphan"], &[]);
        let ev = eval_with(
            &root,
            vec![file(
                "docs/observability/EVENT_REGISTRY.yaml",
                ChangeKind::Modified,
                vec![entry_line("fixture_orphan")],
            )],
        );
        match ev {
            Evaluation::Fail {
                detail,
                remediation,
            } => {
                assert!(detail.contains("register-without-emit"), "{detail}");
                assert!(remediation.contains("scanner-anchor"), "{remediation}");
                assert!(
                    remediation.contains("event-registry-reserved.txt"),
                    "{remediation}"
                );
            }
            _ => panic!("expected fail"),
        }
    }

    #[test]
    fn registry_entry_with_existing_tree_emit_passes() {
        // Reconciliation commit: entry added for a kind already emitted in
        // the tree (but not in this diff).
        let root = fixture_root("reconcile", &["fixture_existing"], &[]);
        let coord = root.join("scripts/coord");
        std::fs::create_dir_all(&coord).unwrap();
        std::fs::write(
            coord.join("emitter.sh"),
            format!("{}\n", emit_line("fixture_existing")),
        )
        .unwrap();
        let ev = eval_with(
            &root,
            vec![file(
                "docs/observability/EVENT_REGISTRY.yaml",
                ChangeKind::Modified,
                vec![entry_line("fixture_existing")],
            )],
        );
        assert!(
            matches!(ev, Evaluation::Pass(_)),
            "existing tree emit should pair"
        );
    }

    #[test]
    fn literal_extraction_handles_spacing_and_rejects_non_idents() {
        let n = kind_needle();
        assert_eq!(
            extract_kind_literals(&format!("x {n} : \"spaced_ok\" y")),
            vec!["spaced_ok"]
        );
        assert_eq!(
            extract_kind_literals(&format!("{n}:\"trailing-junk!\"")),
            Vec::<String>::new()
        );
        assert_eq!(
            extract_kind_literals(&format!("{n}:\"9starts_with_digit\"")),
            Vec::<String>::new()
        );
        assert_eq!(
            extract_kind_literals("no needle here"),
            Vec::<String>::new()
        );
    }

    #[test]
    fn registry_line_parse() {
        assert_eq!(
            parse_registry_entry_line(&entry_line("some_kind")),
            Some("some_kind".to_string())
        );
        assert_eq!(parse_registry_entry_line("  - emitter: x"), None);
        assert_eq!(parse_registry_entry_line("plain text"), None);
    }
}
