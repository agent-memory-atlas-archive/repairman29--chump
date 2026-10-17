//! INFRA-8220 — layer-aware dispatch model defaults.
//!
//! When `chump dispatch <GAP>` runs **without** an explicit `--model`, pick a
//! sensible default by inspecting the gap's file footprint — the `--paths`
//! lease scope plus any path hints parsed out of the gap description:
//!
//!   - any `.rs` under `src/` or `crates/`  → `opus`   + a 3600s subagent budget
//!     (Rust owns invariants per PHASE-R R6; it needs the strongest model and
//!     more wall-clock to land a correct, test-backed change)
//!   - **only** shell / yaml / markdown      → `sonnet` + an 1800s budget
//!     (glue + docs are cheaper and lower-stakes)
//!
//! A concrete `model:` on the gap's matched `docs/dispatch/routing.yaml` route
//! still overrides this heuristic — operators keep the routing table as the
//! final say. The selection is a pure function ([`select_default_model`]) so
//! both branches and the override are unit-testable; the thin CLI arm in
//! `main.rs` resolves the routing override, calls it, sets the budget env var,
//! and logs the choice via [`emit_dispatch_model_selected`]
//! (`kind=dispatch_model_selected`).

/// Model id the Rust-under-`src/`/`crates/` branch selects.
pub const RUST_MODEL: &str = "opus";
/// Model id the shell/yaml/markdown-only branch selects.
pub const DOCS_MODEL: &str = "sonnet";
/// Subagent budget (seconds) for the Rust branch.
pub const RUST_BUDGET_SECS: u64 = 3600;
/// Subagent budget (seconds) for the shell/yaml/markdown branch.
pub const DOCS_BUDGET_SECS: u64 = 1800;

/// Which rule produced a [`ModelSelection`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Layer {
    /// At least one `.rs` file under `src/` or `crates/` in the footprint.
    RustSrc,
    /// Footprint has path signals, all of them shell/yaml/markdown.
    ShellDocs,
    /// A `docs/dispatch/routing.yaml` route pinned a concrete model.
    RoutingOverride,
}

/// The resolved default: model id, subagent budget, machine layer, and a
/// human-readable reason (logged verbatim in `dispatch_model_selected`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ModelSelection {
    pub model: String,
    pub budget_secs: u64,
    pub reason: String,
    pub layer: Layer,
}

/// Strip surrounding punctuation operators / code-span backticks / quotes so a
/// path mentioned inline in prose (`` `src/foo.rs`, `` or `(crates/bar/x.rs)`)
/// still classifies. Leaves interior `/`/`.` intact.
fn clean(token: &str) -> &str {
    token.trim_matches(|c: char| {
        c.is_whitespace()
            || matches!(
                c,
                '`' | '"' | '\'' | '(' | ')' | '[' | ']' | '{' | '}' | ',' | ';' | ':'
            )
    })
}

/// True for a `.rs` path under `src/` or `crates/` (either rooted or nested
/// under some prefix, e.g. `crates/chump-core/src/x.rs`).
fn is_rust_src(token: &str) -> bool {
    let t = clean(token);
    if !t.ends_with(".rs") {
        return false;
    }
    t.starts_with("src/")
        || t.starts_with("crates/")
        || t.contains("/src/")
        || t.contains("/crates/")
}

/// True for a shell / yaml / markdown path (the "glue + docs" layer).
fn is_docs_glue(token: &str) -> bool {
    let t = clean(token);
    t.ends_with(".sh") || t.ends_with(".yaml") || t.ends_with(".yml") || t.ends_with(".md")
}

/// Yield candidate path tokens from the `--paths` CSV and the description.
/// `--paths` is comma-separated; the description is split on whitespace (paths
/// are then de-punctuated by [`clean`] at classification time).
fn tokens<'a>(paths: Option<&'a str>, description: &'a str) -> Vec<&'a str> {
    let mut out: Vec<&str> = Vec::new();
    if let Some(p) = paths {
        out.extend(p.split(',').map(str::trim).filter(|s| !s.is_empty()));
    }
    out.extend(description.split_whitespace());
    out
}

/// Pure layer-aware default selector. Returns `None` when the footprint has no
/// recognizable path signal **and** no routing override — the caller then
/// leaves the model unset (preserving the pre-INFRA-8220 behavior).
///
/// `routing_override` is the concrete `model:` from the gap's matched
/// `docs/dispatch/routing.yaml` route (`None` when the route pins no model, or
/// no route matched); when present it wins over the footprint heuristic.
pub fn select_default_model(
    paths: Option<&str>,
    description: &str,
    routing_override: Option<&str>,
) -> Option<ModelSelection> {
    let mut rust = false;
    let mut docs = false;
    for tok in tokens(paths, description) {
        if is_rust_src(tok) {
            rust = true;
        } else if is_docs_glue(tok) {
            docs = true;
        }
    }

    // Footprint branch (before any override).
    let base: Option<ModelSelection> = if rust {
        Some(ModelSelection {
            model: RUST_MODEL.to_string(),
            budget_secs: RUST_BUDGET_SECS,
            reason: format!(".rs under src/ or crates/ → {RUST_MODEL} ({RUST_BUDGET_SECS}s)"),
            layer: Layer::RustSrc,
        })
    } else if docs {
        Some(ModelSelection {
            model: DOCS_MODEL.to_string(),
            budget_secs: DOCS_BUDGET_SECS,
            reason: format!("only shell/yaml/markdown → {DOCS_MODEL} ({DOCS_BUDGET_SECS}s)"),
            layer: Layer::ShellDocs,
        })
    } else {
        None
    };

    // routing.yaml route with an explicit model still overrides the heuristic.
    if let Some(m) = routing_override.map(str::trim).filter(|m| !m.is_empty()) {
        let budget = base.as_ref().map_or(DOCS_BUDGET_SECS, |b| b.budget_secs);
        let base_note = base
            .as_ref()
            .map_or_else(|| "no footprint signal".to_string(), |b| b.reason.clone());
        return Some(ModelSelection {
            model: m.to_string(),
            budget_secs: budget,
            reason: format!("routing.yaml route pinned model={m} (overrides: {base_note})"),
            layer: Layer::RoutingOverride,
        });
    }

    base
}

// scanner-anchor: "kind":"dispatch_model_selected"
/// Append a `kind=dispatch_model_selected` event to `ambient.jsonl` (and emit
/// over NATS unless `CHUMP_AMBIENT_NATS=0`). Mirrors
/// `dispatch.rs::emit_dispatch_exit`'s best-effort append pattern — failures
/// are swallowed so logging can never break a dispatch.
pub fn emit_dispatch_model_selected(gap_id: &str, sel: &ModelSelection) {
    let repo_root = crate::repo_path::runtime_base();
    let lock_dir = repo_root.join(".chump-locks");
    let _ = std::fs::create_dir_all(&lock_dir);
    let ambient_path = std::env::var("CHUMP_AMBIENT_LOG")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| lock_dir.join("ambient.jsonl"));

    let session = crate::ambient_stream::env_session_id().unwrap_or_else(|| "unknown".to_string());
    let ts = chrono::Utc::now().format("%Y-%m-%dT%H:%M:%SZ").to_string();
    let reason_escaped = sel.reason.replace('\\', "\\\\").replace('"', "\\\"");
    let layer = match sel.layer {
        Layer::RustSrc => "rust_src",
        Layer::ShellDocs => "shell_docs",
        Layer::RoutingOverride => "routing_override",
    };

    let line = format!(
        "{{\"ts\":\"{ts}\",\"kind\":\"dispatch_model_selected\",\"session\":\"{session}\",\
         \"gap_id\":\"{gap_id}\",\"model\":\"{model}\",\"budget_secs\":{budget},\
         \"layer\":\"{layer}\",\"reason\":\"{reason_escaped}\"}}",
        model = sel.model,
        budget = sel.budget_secs,
    );

    use std::io::Write as _;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&ambient_path)
    {
        let _ = writeln!(f, "{line}");
    }

    if std::env::var("CHUMP_AMBIENT_NATS").as_deref() != Ok("0") {
        let _ = std::process::Command::new("chump-coord")
            .arg("emit")
            .arg("dispatch_model_selected")
            .arg(format!("gap_id={gap_id}"))
            .arg(format!("model={}", sel.model))
            .arg(format!("budget_secs={}", sel.budget_secs))
            .arg(format!("layer={layer}"))
            .status();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rust_src_selects_opus_3600() {
        let sel = select_default_model(Some("src/dispatch.rs"), "", None)
            .expect("rust footprint selects a model");
        assert_eq!(sel.model, "opus");
        assert_eq!(sel.budget_secs, 3600);
        assert_eq!(sel.layer, Layer::RustSrc);
    }

    #[test]
    fn crates_src_rust_selects_opus() {
        let sel = select_default_model(Some("crates/chump-core/src/lib.rs"), "", None).unwrap();
        assert_eq!(sel.model, "opus");
        assert_eq!(sel.budget_secs, 3600);
        assert_eq!(sel.layer, Layer::RustSrc);
    }

    #[test]
    fn shell_yaml_markdown_only_selects_sonnet_1800() {
        let sel = select_default_model(
            Some("scripts/coord/foo.sh,docs/dispatch/routing.yaml,README.md"),
            "",
            None,
        )
        .expect("docs/glue footprint selects a model");
        assert_eq!(sel.model, "sonnet");
        assert_eq!(sel.budget_secs, 1800);
        assert_eq!(sel.layer, Layer::ShellDocs);
    }

    #[test]
    fn mixed_footprint_prefers_rust() {
        // Any .rs under src/ wins even when shell/yaml are also present.
        let sel =
            select_default_model(Some("scripts/x.sh,src/main.rs,docs/a.md"), "", None).unwrap();
        assert_eq!(sel.model, "opus");
        assert_eq!(sel.layer, Layer::RustSrc);
    }

    #[test]
    fn description_path_hints_are_scanned() {
        // No --paths; the .rs hint lives in the description prose/backticks.
        let sel = select_default_model(
            None,
            "Rough shape: edit `crates/chump-gap-store/src/store.rs` to add a column.",
            None,
        )
        .unwrap();
        assert_eq!(sel.model, "opus");
        assert_eq!(sel.layer, Layer::RustSrc);
    }

    #[test]
    fn rs_outside_src_or_crates_does_not_trigger_rust_branch() {
        // A .rs not under src/ or crates/ is not a Rust-invariant signal.
        let sel = select_default_model(Some("examples/demo.rs,notes.md"), "", None).unwrap();
        // Falls to the docs branch via notes.md; the examples/demo.rs is ignored.
        assert_eq!(sel.model, "sonnet");
        assert_eq!(sel.layer, Layer::ShellDocs);
    }

    #[test]
    fn no_signal_returns_none() {
        assert!(select_default_model(Some("data/blob.bin"), "no paths here", None).is_none());
        assert!(select_default_model(None, "", None).is_none());
    }

    #[test]
    fn routing_override_wins_over_rust_branch() {
        let sel = select_default_model(Some("src/dispatch.rs"), "", Some("sonnet"))
            .expect("override selects a model");
        assert_eq!(sel.model, "sonnet");
        assert_eq!(sel.layer, Layer::RoutingOverride);
        // Budget is carried over from the footprint branch (rust → 3600).
        assert_eq!(sel.budget_secs, 3600);
        assert!(sel.reason.contains("routing.yaml"));
    }

    #[test]
    fn routing_override_wins_over_docs_branch() {
        let sel = select_default_model(Some("scripts/x.sh"), "", Some("opus")).unwrap();
        assert_eq!(sel.model, "opus");
        assert_eq!(sel.layer, Layer::RoutingOverride);
        assert_eq!(sel.budget_secs, 1800);
    }

    #[test]
    fn routing_override_applies_with_no_footprint_signal() {
        let sel = select_default_model(None, "no path hints", Some("opus")).unwrap();
        assert_eq!(sel.model, "opus");
        assert_eq!(sel.layer, Layer::RoutingOverride);
        assert_eq!(sel.budget_secs, 1800);
    }

    #[test]
    fn empty_routing_override_is_ignored() {
        // An empty/whitespace override must not pre-empt the footprint branch.
        let sel = select_default_model(Some("src/main.rs"), "", Some("  ")).unwrap();
        assert_eq!(sel.model, "opus");
        assert_eq!(sel.layer, Layer::RustSrc);
    }
}
