//! INFRA-1541: `chump pr ac-coverage <PR_NUMBER>`
//!
//! CREDIBLE: pre-merge AC coverage gate — exits 0 iff every AC bullet of the
//! referenced gap is covered by the PR diff. Exits 1 with a numbered miss-list
//! on uncovered bullets (unless advisory mode is active).
//!
//! Testability:
//!   - `CHUMP_GH` env var overrides the `gh` binary path (mock injection).
//!   - `CHUMP_REPO_ROOT` env var overrides the repo root (fake gap YAMLs).

use std::process::Command;

use chump_ambient_cli::ambient_emit::{emit, EmitArgs};

// ── public types ──────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CoverageStatus {
    Pass,
    Miss,
    NoGapRef,
    Disabled,
    Advisory,
}

#[derive(Debug, Clone)]
pub struct BulletResult {
    pub index: usize,
    pub text: String,
    pub covered: bool,
    pub waived: bool,
    pub waive_reason: Option<String>,
    /// Which rule numbers (1–4) matched.
    pub rules_hit: Vec<u8>,
    /// CREDIBLE-281: true when this bullet is a proof/verification AC (its
    /// text asserts a live outcome via a `PROVEN-BY <outcome>` / `PROOF:`
    /// marker) rather than a descriptive AC. Proof bullets are never scored
    /// by the diff-based keyword rules (a–d) — those only prove code
    /// changed, not that the claimed live outcome actually happened — they
    /// are scored by [`check_live_outcome`] instead.
    pub is_proof: bool,
    /// Human-readable detail of the live-outcome check for a proof bullet
    /// (what was probed and what it found). `None` for non-proof bullets.
    pub proof_detail: Option<String>,
}

#[derive(Debug, Clone)]
pub struct AcCoverageResult {
    pub pr_number: u64,
    pub gap_id: Option<String>,
    pub status: CoverageStatus,
    pub bullets: Vec<BulletResult>,
}

impl AcCoverageResult {
    /// Calibrated confidence in `0.0..=1.0` that the PR satisfies the gap's
    /// acceptance criteria — the judgment organ's score (EFFECTIVE-331 piece 2),
    /// derived from the covered-bullet fraction via [`crate::confidence`]. A
    /// bare pass/miss is a boolean; this is the score the OS can act on
    /// (ship / iterate / hold). Waived bullets count as covered. With no bullets
    /// to check: a `Pass` (no criteria) is fully satisfied (1.0); a
    /// `Disabled` / `NoGapRef` result can't be judged, so it returns the neutral
    /// prior (0.5).
    pub fn confidence(&self) -> f64 {
        if self.bullets.is_empty() {
            return match self.status {
                CoverageStatus::Pass => 1.0,
                _ => 0.5,
            };
        }
        let covered = self.bullets.iter().filter(|b| b.covered).count();
        crate::confidence::confidence_from_coverage(covered as f64 / self.bullets.len() as f64)
    }
}

// ── helpers ───────────────────────────────────────────────────────────────────

fn gh_cmd() -> String {
    std::env::var("CHUMP_GH").unwrap_or_else(|_| "gh".to_string())
}

fn run_gh(args: &[&str]) -> Result<String, String> {
    let out = Command::new(gh_cmd())
        .args(args)
        .output()
        .map_err(|e| format!("gh exec failed: {e}"))?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    } else {
        Err(String::from_utf8_lossy(&out.stderr).trim().to_string())
    }
}

// ── title parser ──────────────────────────────────────────────────────────────

/// Parse a `<DOMAIN>-N` gap reference from a PR title.
/// Returns the first match, e.g. `"INFRA-1541"`.
pub fn parse_gap_id(title: &str) -> Option<String> {
    // Regex equivalent: [A-Z][A-Z0-9]+-\d+
    // We do it manually to avoid pulling in the regex crate just for this.
    let bytes = title.as_bytes();
    let len = bytes.len();
    let mut i = 0;
    while i < len {
        // Need an uppercase ASCII letter to start
        if bytes[i].is_ascii_uppercase() {
            let start = i;
            // consume uppercase-alphanumeric run
            while i < len && (bytes[i].is_ascii_uppercase() || bytes[i].is_ascii_digit()) {
                i += 1;
            }
            let domain_len = i - start;
            if domain_len >= 1 && i < len && bytes[i] == b'-' {
                i += 1; // consume '-'
                let num_start = i;
                while i < len && bytes[i].is_ascii_digit() {
                    i += 1;
                }
                if i > num_start {
                    // matched!
                    return Some(title[start..i].to_string());
                }
            }
        } else {
            i += 1;
        }
    }
    None
}

// ── AC bullet loader ──────────────────────────────────────────────────────────

/// Load acceptance_criteria bullets from `docs/gaps/<GAP_ID>.yaml`.
/// Supports `acceptance_criteria:` as a list-of-strings YAML block.
/// The YAML file may be a list (starts with `- id:`) or a top-level object.
pub fn load_ac_bullets(gap_id: &str) -> Result<Vec<String>, String> {
    // CREDIBLE-178: read acceptance criteria from the canonical state.db via
    // `chump gap show <ID> --json`, NOT the docs/gaps/<ID>.yaml mirror. That
    // per-file YAML mirror was removed by ZERO-WASTE-020, so the old file read
    // ALWAYS failed with "no such file" → this checker silently treated every PR
    // as a pass and could never detect a miss. That dead read is the root cause
    // of the label-drift where gaps (INFRA-3490/3489) flipped to 'done' with
    // uncovered acceptance criteria. state.db is canonical (see CLAUDE.md).
    let chump_bin = std::env::var("CHUMP_REAL_BINARY").unwrap_or_else(|_| "chump".to_string());
    let out = Command::new(&chump_bin)
        .args(["gap", "show", gap_id, "--json"])
        .output()
        .map_err(|e| format!("cannot run `{chump_bin} gap show {gap_id} --json`: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "`chump gap show {gap_id} --json` failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    let v: serde_json::Value = serde_json::from_slice(&out.stdout)
        .map_err(|e| format!("cannot parse `chump gap show {gap_id} --json`: {e}"))?;
    // `acceptance_criteria` is a JSON array of strings, serialized AS A STRING
    // (double-encoded) in the gap row — parse the inner array.
    let ac_field = v
        .get("acceptance_criteria")
        .and_then(|x| x.as_str())
        .unwrap_or("");
    if ac_field.trim().is_empty() {
        return Ok(vec![]);
    }
    Ok(serde_json::from_str::<Vec<String>>(ac_field).unwrap_or_default())
}

// ── waiver parser ─────────────────────────────────────────────────────────────

/// Parse `AC-Coverage-Waive: <bullet-index>: <reason>` lines from PR body +
/// commit messages. Returns `(index, reason)` pairs.
fn parse_waivers(text: &str) -> Vec<(usize, String)> {
    let mut out = Vec::new();
    for line in text.lines() {
        // Trim leading whitespace (bodies can have indentation)
        let line = line.trim();
        if let Some(rest) = line.strip_prefix("AC-Coverage-Waive:").map(str::trim) {
            // rest = "<index>: <reason>" or "<index>:<reason>"
            if let Some((idx_str, reason)) = rest.split_once(':') {
                if let Ok(idx) = idx_str.trim().parse::<usize>() {
                    out.push((idx, reason.trim().to_string()));
                }
            }
        }
    }
    out
}

// ── coverage rules ────────────────────────────────────────────────────────────

static COMMON_WORDS: &[&str] = &[
    "the", "and", "for", "with", "that", "this", "from", "have", "will", "must", "each", "when",
    "where", "into", "then", "than", "some", "file", "path", "rule", "item", "test", "first",
    "last", "bool", "true", "false", "none", "null", "zero", "both", "only", "list", "all", "any",
    "new", "add", "get", "set", "run", "via", "per", "not", "use", "has", "are", "its", "one",
    "two", "may", "can", "but", "also", "emit", "does", "been", "every", "should", "given",
    "under", "after", "before", "return", "check", "value", "match", "cover",
];

/// Extract candidate symbols/keywords from a bullet for Rule (b).
/// 4+ chars, alphanumeric/underscore/hyphen, skip common words.
fn extract_keywords(bullet: &str) -> Vec<String> {
    bullet
        .split(|c: char| !c.is_alphanumeric() && c != '_' && c != '-')
        .filter(|w| {
            let l = w.len();
            if l < 4 {
                return false;
            }
            // skip pure-numeric tokens
            if w.chars().all(|c| c.is_ascii_digit()) {
                return false;
            }
            let lower = w.to_ascii_lowercase();
            !COMMON_WORDS.contains(&lower.as_str())
        })
        .map(|w| w.to_string())
        .collect()
}

/// Rule (a): any file path mentioned literally in the bullet appears as
/// `+++ b/<path>` in the diff.
fn rule_a(bullet: &str, diff: &str) -> bool {
    // Extract path-like tokens: anything with '/' or a known extension.
    for token in bullet.split_whitespace() {
        let token = token.trim_matches(|c: char| "'\"`(),;".contains(c));
        if token.contains('/')
            || token.ends_with(".rs")
            || token.ends_with(".sh")
            || token.ends_with(".yaml")
            || token.ends_with(".yml")
            || token.ends_with(".toml")
            || token.ends_with(".md")
        {
            let needle = format!("+++ b/{token}");
            if diff.contains(&needle) {
                return true;
            }
            // Also check without leading b/ (some diff formats)
            if diff.contains(token) && diff.contains("+++ b/") {
                // only if the path appears as a diff file header
                for line in diff.lines() {
                    if line.starts_with("+++ b/") && line.contains(token) {
                        return true;
                    }
                }
            }
        }
    }
    false
}

/// CREDIBLE-180: true if a trimmed diff-content line is comment-only (Rust
/// `//` / `/* */` continuation, or shell/YAML `#`). A stub that describes
/// its own TODO in a bullet's own words must not count as coverage.
fn is_comment_only_line(trimmed: &str) -> bool {
    trimmed.starts_with("//")
        || trimmed.starts_with('#')
        || trimmed.starts_with("/*")
        || trimmed.starts_with('*')
}

/// CREDIBLE-180: concatenated *added* (`+`, not `+++` file headers),
/// non-comment-only diff content lines, leading `+` stripped. rule_b uses
/// this instead of the raw diff text so a keyword sitting only in a TODO
/// comment or in unrelated context/removed lines doesn't count as coverage.
fn added_non_comment_lines(diff: &str) -> String {
    let mut out = String::new();
    for line in diff.lines() {
        if line.starts_with("+++ ") || !line.starts_with('+') {
            continue;
        }
        let content = &line[1..];
        if is_comment_only_line(content.trim_start()) {
            continue;
        }
        out.push_str(content);
        out.push('\n');
    }
    out
}

/// Rule (b): any keyword from the bullet (4+ chars, non-common) appears in
/// an added, non-comment-only diff line.
///
/// CREDIBLE-180 (hardening): previously matched the bullet's own keywords
/// against the *raw* diff text, so a TODO comment or dead stub restating
/// the bullet's own words passed as "covered" with zero real logic --
/// confirmed gameable by CREDIBLE-177's redteam fixture set. Now requires
/// the keyword to land in an added, non-comment line.
fn rule_b(bullet: &str, diff: &str) -> bool {
    let added = added_non_comment_lines(diff);
    for kw in extract_keywords(bullet) {
        if added.contains(&*kw) {
            return true;
        }
    }
    false
}

/// Rule (c): commit body contains `Closes-AC: <text>` where `<text>` is
/// either an exact match of the bullet, or a substring/prefix match that
/// covers at least half the bullet's length.
///
/// CREDIBLE-180 (hardening): the original rule accepted a 40-char
/// prefix-substring match in *either* direction with no minimum-coverage
/// requirement, so `Closes-AC: <first few words of the bullet>` passed
/// against a diff that touched nothing the bullet described -- confirmed
/// gameable by CREDIBLE-177's redteam fixture set (a 29-char echo of a
/// 132-char bullet was enough). Real usage across this repo's history
/// includes short, deliberate pointer trailers like
/// `Closes-AC: scripts/ci/test-pr-ac-coverage.sh` that are NOT the full
/// bullet text, so an exact-match-only rule would false-negative genuinely
/// covered work -- checked against real merged commits before landing this.
/// The half-length floor keeps short, low-effort prefix-echoing out while
/// still accepting a trailer that substantively restates the bullet.
fn rule_c(bullet: &str, commit_text: &str) -> bool {
    let bullet_trimmed = bullet.trim();
    let half_len = bullet_trimmed.len().div_ceil(2);
    for line in commit_text.lines() {
        let line = line.trim();
        if let Some(rest) = line.strip_prefix("Closes-AC:").map(str::trim) {
            if rest == bullet_trimmed {
                return true;
            }
            if rest.len() >= half_len
                && (bullet_trimmed.contains(rest)
                    || rest.starts_with(bullet_trimmed)
                    || bullet_trimmed.starts_with(rest))
            {
                return true;
            }
        }
    }
    false
}

/// Rule (d): any `+++ b/scripts/ci/test-*.sh` or `+++ b/tests/` file in the
/// diff mentions a keyword from the bullet in an added, non-comment-only
/// line.
///
/// CREDIBLE-180 (hardening): previously matched bullet keywords against
/// *all* added lines in a test file, including comments -- so a no-op
/// `exit 0` test whose only content was a comment restating the bullet
/// passed as "covered" -- confirmed gameable by CREDIBLE-177's redteam
/// fixture set. Now skips comment-only added lines the same way rule_b does.
fn rule_d(bullet: &str, diff: &str) -> bool {
    // Collect non-comment-only lines that add content to test files.
    let mut in_test_file = false;
    let mut test_additions = String::new();
    for line in diff.lines() {
        if line.starts_with("+++ b/scripts/ci/test-") || line.starts_with("+++ b/tests/") {
            in_test_file = true;
            continue;
        }
        if line.starts_with("+++ b/") || line.starts_with("diff --git") {
            in_test_file = false;
            continue;
        }
        if in_test_file && line.starts_with('+') {
            let content = &line[1..];
            if is_comment_only_line(content.trim_start()) {
                continue;
            }
            test_additions.push_str(content);
            test_additions.push('\n');
        }
    }
    if test_additions.is_empty() {
        return false;
    }
    for kw in extract_keywords(bullet) {
        if test_additions.contains(&*kw) {
            return true;
        }
    }
    false
}

/// Check which rules (1–4) cover a bullet given diff text and commit messages.
fn check_coverage(bullet: &str, diff: &str, commit_text: &str) -> Vec<u8> {
    let mut hit = Vec::new();
    if rule_a(bullet, diff) {
        hit.push(1);
    }
    if rule_b(bullet, diff) {
        hit.push(2);
    }
    if rule_c(bullet, commit_text) {
        hit.push(3);
    }
    if rule_d(bullet, diff) {
        hit.push(4);
    }
    hit
}

// ── proof-AC gate (CREDIBLE-281) ────────────────────────────────────────────
//
// INFRA-3598 (and INFRA-3593 before it) shipped `done` while their AC text
// explicitly said `PROVEN by <live outcome>` — and the claimed outcome
// (scorecard organ recovering to green) never happened. The heuristic rules
// above (a–d) only check that the PR's *diff* mentions the bullet's file
// paths / keywords; they cannot and do not check that a live system
// actually reached the claimed state. Treating a proof bullet as coverable
// by those rules is exactly how a false-done slips through: the diff can
// keyword-match "scorecard organ recovering to green" while the organ is
// still failed.
//
// The fix: classify each bullet as proof vs. descriptive. A proof bullet is
// NEVER scored by rules a–d — it is only "covered" when
// `check_live_outcome` can positively confirm the claimed outcome against
// real, checkable state (a systemd unit's live ActiveState, an emitted
// ambient event, or an HTTP endpoint). When the bullet names no
// mechanically-checkable target, the gate fails closed (uncovered) rather
// than rubber-stamping the claim — this is what rejects the INFRA-3598
// class: "the scorecard organ recovers to green" names an outcome, not a
// literal unit/event/endpoint the gate can probe, so it stays uncovered
// until the bullet (or a companion trailer) names something checkable.

/// True when `bullet` is a proof/verification AC — its text asserts a live
/// outcome via a `PROVEN-BY`/`PROVEN BY`/`PROOF:`/`PROOF-BY` marker — as
/// opposed to a descriptive AC that just states what the PR should contain.
fn is_proof_bullet(bullet: &str) -> bool {
    let lower = bullet.to_ascii_lowercase();
    lower.contains("proven-by")
        || lower.contains("proven by")
        || lower.contains("proof-by")
        || lower.contains("proof by")
        || lower.contains("proof:")
}

fn systemctl_bin() -> String {
    std::env::var("CHUMP_AC_GATE_SYSTEMCTL_BIN").unwrap_or_else(|_| "systemctl".to_string())
}

/// INFRA-3728: run `ssh <node> systemctl is-active <unit>` against a remote
/// node and return the trimmed stdout. The ssh binary can be stubbed via
/// `CHUMP_AC_GATE_SYSTEMCTL_BIN`.
fn run_remote_systemctl(node: &str, unit: &str) -> Result<String, String> {
    let ssh_bin =
        std::env::var("CHUMP_AC_GATE_SYSTEMCTL_BIN").unwrap_or_else(|_| "ssh".to_string());
    let output = Command::new(&ssh_bin)
        .arg(node)
        .arg("systemctl")
        .arg("is-active")
        .arg(unit)
        .output()
        .map_err(|e| format!("failed to spawn `{ssh_bin}` for {node}: {e}"))?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        return Err(format!(
            "`{ssh_bin} {node} systemctl is-active {unit}` exited with {}: {stderr}",
            output.status
        ));
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

/// INFRA-7098: resolve the hostname that owns `unit` by reading its
/// `CapabilityManifest` from the NATS capabilities KV
/// (`chump_coord::capability::resolve_target_node`). Fails closed to `None`
/// on any error — no NATS reachable, no manifest for `unit`, a stale
/// manifest, or a manifest with no `machine` set — so callers fall back to
/// the pre-existing local-only probe rather than erroring out.
///
/// `CoordClient::connect` already bounds the NATS dial with its own
/// `tokio::time::timeout` (`CHUMP_NATS_TIMEOUT_MS`, default 500ms), so a
/// bare current-thread runtime is enough to drive it synchronously without
/// risking a hang when NATS is unreachable (the common case in unit tests
/// and most CI runs).
fn resolve_target_node_for_unit(unit: &str) -> Option<String> {
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .ok()?;
    rt.block_on(async {
        let client = chump_coord::CoordClient::connect_or_skip().await?;
        chump_coord::capability::resolve_target_node(&client.capabilities_kv, unit)
            .await
            .ok()
    })
}

/// True when `node` names the current host, per the same
/// hostname-or-`CHUMP_MACHINE_LABEL` lookup [`chump_coord::capability`] uses
/// to populate a manifest's `machine` field — so the comparison matches how
/// the field was written in the first place.
fn is_current_host(node: &str) -> bool {
    chump_coord::capability::hostname_or_label()
        .map(|h| h == node)
        .unwrap_or(false)
}

fn ambient_log_path() -> String {
    std::env::var("CHUMP_AMBIENT_LOG").unwrap_or_else(|_| ".chump-locks/ambient.jsonl".to_string())
}

fn strip_token_punct(tok: &str) -> &str {
    tok.trim_matches(|c: char| matches!(c, '\'' | '"' | '`' | '(' | ')' | ',' | ';' | ':' | '.'))
}

/// Find a literal `<name>.service` / `<name>.timer` token in the bullet —
/// the concrete, checkable target for an "organ recovers to green"-shaped
/// claim.
fn find_systemd_unit_token(bullet: &str) -> Option<String> {
    for raw in bullet.split_whitespace() {
        let stripped = raw.trim_end_matches(|c: char| matches!(c, ',' | ';' | ')' | '"' | '`'));
        if stripped.ends_with(".service") || stripped.ends_with(".timer") {
            let cleaned = stripped
                .trim_start_matches(|c: char| matches!(c, '\'' | '"' | '`' | '(' | ',' | ';'));
            return Some(cleaned.to_string());
        }
    }
    None
}

/// Find an explicit `kind=<event_name>` marker — the concrete, checkable
/// target for an "emits a deploy audit event" claim.
fn find_event_kind_token(bullet: &str) -> Option<String> {
    let pos = bullet.find("kind=")?;
    let rest = &bullet[pos + "kind=".len()..];
    let tok: String = rest
        .chars()
        .take_while(|c| c.is_alphanumeric() || *c == '_')
        .collect();
    if tok.is_empty() {
        None
    } else {
        Some(tok)
    }
}

/// Find a literal `http(s)://` URL — the concrete, checkable target for an
/// "endpoint responds" claim.
fn find_url_token(bullet: &str) -> Option<String> {
    for raw in bullet.split_whitespace() {
        let t = strip_token_punct(raw);
        if t.starts_with("http://") || t.starts_with("https://") {
            return Some(t.to_string());
        }
    }
    None
}

/// Check whether a proof bullet's claimed live outcome is actually true
/// right now. Returns `(verified, detail)`. Fails closed: a bullet whose
/// text names no mechanically-checkable target (no literal
/// `<unit>.service`/`.timer`, `kind=<event>`, or URL) is `(false, ..)` —
/// the gate never takes a proof claim on faith.
fn check_live_outcome(bullet: &str) -> (bool, String) {
    if let Some(unit) = find_systemd_unit_token(bullet) {
        // INFRA-7098: resolve which host actually owns `unit` via the
        // capability manifest KV, and probe that host — local systemctl if
        // it's us, `ssh <node> systemctl` (INFRA-3728) if it's someone else.
        // `resolve_target_node_for_unit` fails closed to `None` (no NATS, no
        // manifest, stale manifest, no machine field) so the pre-existing
        // local-only path is exactly what runs when target-node resolution
        // isn't available — AC-2/AC-4.
        if let Some(node) = resolve_target_node_for_unit(&unit) {
            if !is_current_host(&node) {
                return match run_remote_systemctl(&node, &unit) {
                    Ok(state) => {
                        let ok = state == "active";
                        (
                            ok,
                            format!("ssh {node} systemctl is-active {unit} -> \"{state}\""),
                        )
                    }
                    Err(e) => (
                        false,
                        format!("remote check of {unit} on {node} failed: {e}"),
                    ),
                };
            }
        }
        return match Command::new(systemctl_bin())
            .args(["is-active", &unit])
            .output()
        {
            Ok(out) => {
                let state = String::from_utf8_lossy(&out.stdout).trim().to_string();
                let ok = state == "active";
                (ok, format!("systemctl is-active {unit} -> \"{state}\""))
            }
            Err(e) => (
                false,
                format!("systemctl unavailable ({e}); cannot confirm {unit}"),
            ),
        };
    }
    if let Some(kind) = find_event_kind_token(bullet) {
        let path = ambient_log_path();
        let needle = format!("\"kind\":\"{kind}\"");
        let found = std::fs::read_to_string(&path)
            .map(|s| s.contains(&needle))
            .unwrap_or(false);
        return (
            found,
            format!("ambient log {path} contains kind={kind} -> {found}"),
        );
    }
    if let Some(url) = find_url_token(bullet) {
        let curl_bin =
            std::env::var("CHUMP_AC_GATE_CURL_BIN").unwrap_or_else(|_| "curl".to_string());
        return match Command::new(curl_bin)
            .args([
                "-sf",
                "-o",
                "/dev/null",
                "-w",
                "%{http_code}",
                "--max-time",
                "5",
                &url,
            ])
            .output()
        {
            Ok(out) if out.status.success() => {
                let code = String::from_utf8_lossy(&out.stdout).trim().to_string();
                let ok = code.starts_with('2');
                (ok, format!("curl {url} -> {code}"))
            }
            _ => (false, format!("endpoint {url} did not respond 2xx")),
        };
    }
    (
        false,
        "proof-AC names no mechanically-checkable live target (no literal \
         <unit>.service/.timer, kind=<event>, or URL) -- failing closed, \
         diff keyword-match does not count as proof"
            .to_string(),
    )
}

// ── proof-AC synthesis on-ramp (PEER-VERI-08, INFRA-3655) ──────────────────
//
// CREDIBLE-281 above makes proof bullets un-fakeable IF one exists — but a
// gap whose author never wrote a `PROVEN-BY` bullet skips the live-outcome
// check entirely by omission, not by honest scoping. A diff that adds/edits
// a systemd unit, an install script, or a deploy path is exactly the class
// where "the diff looks right" and "the thing is actually running" diverge
// (see the CREDIBLE-281 doc comment's INFRA-3598 precedent). This closes
// that gap at AC-synthesis time: when such a diff is detected and no bullet
// in the (stored or synthesized) set is already a proof bullet, inject one
// naming a concrete target lifted straight from the diff — so it is always
// `check_live_outcome`-parseable by construction, never a hallucinated path.

/// True when a unified diff touches a systemd unit, an install script, or a
/// deploy path — the three surfaces where "diff landed" and "thing is live"
/// can diverge. Matches on diff path headers (`diff --git a/X b/X`,
/// `+++ b/X`) so renames/adds/edits are all caught.
fn diff_touches_service_surface(diff: &str) -> bool {
    for line in diff.lines() {
        let path = if let Some(p) = line.strip_prefix("+++ b/") {
            p
        } else if let Some(rest) = line.strip_prefix("diff --git a/") {
            // "diff --git a/<old> b/<new>" — take the b/ side.
            match rest.split(" b/").nth(1) {
                Some(p) => p,
                None => continue,
            }
        } else {
            continue;
        };
        let lower = path.to_ascii_lowercase();
        if lower.ends_with(".service") || lower.ends_with(".timer") {
            return true;
        }
        if lower.contains("systemd/") || lower.contains("launchd/") {
            return true;
        }
        if (lower.contains("/install") || lower.starts_with("install")) && lower.ends_with(".sh") {
            return true;
        }
        if lower.contains("deploy")
            && (lower.ends_with(".sh") || lower.ends_with(".yml") || lower.ends_with(".yaml"))
        {
            return true;
        }
    }
    false
}

/// Pull the first mechanically-checkable target (`<unit>.service`/`.timer`,
/// `kind=<event>`, or a literal URL) out of a diff's *added* lines — the
/// same three shapes [`check_live_outcome`] knows how to probe. Scanning
/// added lines only (not context/removed lines) keeps the extracted target
/// tied to what this PR actually introduced.
fn extract_live_proof_target(diff: &str) -> Option<String> {
    // A new/renamed unit file's path IS the checkable target even when its
    // added *content* never spells out its own filename (a `.service` file's
    // body is `[Unit]`/`[Service]` stanzas, not a self-reference).
    for line in diff.lines() {
        let path = if let Some(p) = line.strip_prefix("+++ b/") {
            Some(p)
        } else if let Some(rest) = line.strip_prefix("diff --git a/") {
            rest.split(" b/").nth(1)
        } else {
            None
        };
        if let Some(p) = path {
            if let Some(name) = p.rsplit('/').next() {
                if name.ends_with(".service") || name.ends_with(".timer") {
                    return Some(name.to_string());
                }
            }
        }
    }
    for line in diff.lines() {
        let added = match line.strip_prefix('+') {
            // Exclude the "+++ b/path" file-header line itself.
            Some(rest) if !rest.starts_with("++ ") && !line.starts_with("+++") => rest,
            _ => continue,
        };
        if let Some(unit) = find_systemd_unit_token(added) {
            return Some(unit);
        }
        if let Some(kind) = find_event_kind_token(added) {
            return Some(format!("kind={kind}"));
        }
        if let Some(url) = find_url_token(added) {
            return Some(url);
        }
    }
    None
}

/// Build a synthesized proof bullet for a service/install/deploy-touching
/// diff, or `None` when the diff doesn't touch that surface, already has a
/// proof bullet, or names no concrete checkable target (fail-open per AC#3
/// — a docs-only or target-less diff gets no injected bullet).
pub(crate) fn maybe_inject_proof_ac(diff: &str, existing_bullets: &[String]) -> Option<String> {
    if !diff_touches_service_surface(diff) {
        return None;
    }
    if existing_bullets.iter().any(|b| is_proof_bullet(b)) {
        return None;
    }
    let target = extract_live_proof_target(diff)?;
    Some(format!(
        "PROVEN-BY {target} — live-outcome check required (this diff touches a \
         systemd unit / install script / deploy path; PEER-VERI-08 INFRA-3655)"
    ))
}

// ── ambient emit wrapper ──────────────────────────────────────────────────────

fn ambient(kind: &str, fields: Vec<(&str, String)>) {
    let args = EmitArgs {
        kind: kind.to_string(),
        fields: fields
            .into_iter()
            .map(|(k, v)| (k.to_string(), v))
            .collect(),
        ..Default::default()
    };
    // Best-effort: ignore emit errors in the coverage gate.
    let _ = emit(&args);
}

// ── JSON render ───────────────────────────────────────────────────────────────

pub fn render_json(result: &AcCoverageResult) -> String {
    let status = match result.status {
        CoverageStatus::Pass => "pass",
        CoverageStatus::Miss => "miss",
        CoverageStatus::NoGapRef => "no_gap_ref",
        CoverageStatus::Disabled => "disabled",
        CoverageStatus::Advisory => "advisory",
    };
    let gap_id = result
        .gap_id
        .as_deref()
        .map(|s| format!(r#""{s}""#))
        .unwrap_or_else(|| "null".to_string());
    let misses: Vec<usize> = result
        .bullets
        .iter()
        .filter(|b| !b.covered && !b.waived)
        .map(|b| b.index)
        .collect();
    let misses_json = misses
        .iter()
        .map(|i| i.to_string())
        .collect::<Vec<_>>()
        .join(",");
    format!(
        r#"{{"status":"{status}","pr_number":{pr},"gap_id":{gap_id},"misses":[{misses_json}],"confidence":{conf:.3}}}"#,
        pr = result.pr_number,
        conf = result.confidence(),
    )
}

// ── main entry point ──────────────────────────────────────────────────────────

pub fn run(pr_number: u64) -> Result<AcCoverageResult, String> {
    // Operator override: gate disabled
    if std::env::var("CHUMP_AC_GATE_ENABLED").as_deref() == Ok("false") {
        ambient(
            "ac_coverage_disabled",
            vec![("pr_number", pr_number.to_string())],
        );
        return Ok(AcCoverageResult {
            pr_number,
            gap_id: None,
            status: CoverageStatus::Disabled,
            bullets: vec![],
        });
    }

    // Fetch PR title + body + commits
    let pr_json_str = run_gh(&[
        "pr",
        "view",
        &pr_number.to_string(),
        "--json",
        "title,body,commits",
    ])?;

    // Parse JSON manually to avoid pulling serde_json as a new dep.
    // We need: title (string), body (string), commits[].messageBody (strings)
    let title = json_extract_string(&pr_json_str, "title").unwrap_or_default();
    let body = json_extract_string(&pr_json_str, "body").unwrap_or_default();
    let commit_bodies = extract_commit_messages(&pr_json_str);

    // Build full text for trailer scanning (PR body + all commit messages)
    let mut trailer_text = body.clone();
    for cb in &commit_bodies {
        trailer_text.push('\n');
        trailer_text.push_str(cb);
    }

    // Parse gap ID from title
    let gap_id = match parse_gap_id(&title) {
        Some(id) => id,
        None => {
            return Ok(AcCoverageResult {
                pr_number,
                gap_id: None,
                status: CoverageStatus::NoGapRef,
                bullets: vec![],
            });
        }
    };

    // Load AC bullets
    let raw_bullets = match load_ac_bullets(&gap_id) {
        Ok(b) if !b.is_empty() => b,
        Ok(_) => {
            // No AC bullets → treat as pass (gap has no AC to check)
            return Ok(AcCoverageResult {
                pr_number,
                gap_id: Some(gap_id),
                status: CoverageStatus::Pass,
                bullets: vec![],
            });
        }
        Err(e) => {
            // Gap YAML missing or unreadable → treat as advisory pass
            eprintln!("ac-coverage: {e} — skipping (no AC YAML found)");
            return Ok(AcCoverageResult {
                pr_number,
                gap_id: Some(gap_id),
                status: CoverageStatus::Pass,
                bullets: vec![],
            });
        }
    };

    // EFFECTIVE-367: score against the resolved bullets (shared with run_with_ac).
    Ok(score_against_bullets(
        pr_number,
        gap_id,
        raw_bullets,
        trailer_text,
        None,
    ))
}

/// EFFECTIVE-367 (COTG): score a PR against acceptance-criteria bullets the caller
/// ALREADY holds — instead of re-deriving the gap id from the PR title (which
/// external-repo PRs lack, degrading `run` to `NoGapRef` → no signal). `gap_id` is
/// for logging/attribution; `repo` is `owner/name` when the PR lives in a different
/// repo than the current one (external-improve path). Empty bullets ⇒ `Pass`.
pub fn run_with_ac(
    repo: &str,
    pr_number: u64,
    gap_id: &str,
    bullets: &[String],
) -> Result<AcCoverageResult, String> {
    if std::env::var("CHUMP_AC_GATE_ENABLED").as_deref() == Ok("false") {
        return Ok(AcCoverageResult {
            pr_number,
            gap_id: Some(gap_id.to_string()),
            status: CoverageStatus::Disabled,
            bullets: vec![],
        });
    }
    if bullets.is_empty() {
        return Ok(AcCoverageResult {
            pr_number,
            gap_id: Some(gap_id.to_string()),
            status: CoverageStatus::Pass,
            bullets: vec![],
        });
    }
    // PR body + commit messages feed waiver parsing + check_coverage's commit_text.
    let repo_opt = if repo.is_empty() { None } else { Some(repo) };
    let pr_json_str = match repo_opt {
        Some(r) => run_gh(&[
            "pr",
            "view",
            &pr_number.to_string(),
            "--repo",
            r,
            "--json",
            "body,commits",
        ]),
        None => run_gh(&[
            "pr",
            "view",
            &pr_number.to_string(),
            "--json",
            "body,commits",
        ]),
    }
    .unwrap_or_default();
    let body = json_extract_string(&pr_json_str, "body").unwrap_or_default();
    let commit_bodies = extract_commit_messages(&pr_json_str);
    let mut trailer_text = body;
    for cb in &commit_bodies {
        trailer_text.push('\n');
        trailer_text.push_str(cb);
    }
    let mut result = score_against_bullets(
        pr_number,
        gap_id.to_string(),
        bullets.to_vec(),
        trailer_text,
        repo_opt,
    );
    // EFFECTIVE-373 (COTG slice 2): the LLM judge is the REAL gate — the heuristic above
    // is a cheap first pass. Opt-in for now (CHUMP_AC_JUDGE_LLM=1) until slice 3 makes it
    // the default hard gate. It overrides each bullet's `covered` with the model's
    // MET/UNMET/PARTIAL judgement and SURFACES the per-bullet reasoning durably (CREDIBLE-207
    // — a gate that hides its reasoning is the failure we're fixing). An un-judged criterion
    // stays as the heuristic said (fail-forward), so a total judge miss can't silently pass.
    if std::env::var("CHUMP_AC_JUDGE_LLM").as_deref() == Ok("1") {
        if let Some(verdicts) = llm_judge_ac(repo_opt, pr_number, gap_id, bullets) {
            for v in &verdicts {
                if let Some(b) = result.bullets.get_mut(v.index) {
                    // CREDIBLE-281: the LLM judge only reads the diff — it has
                    // no more access to live system state than the heuristic
                    // rules do, so it must not override a proof bullet's
                    // `check_live_outcome` verdict (that would let a
                    // plausible-sounding diff talk the gate into believing an
                    // unproven live outcome).
                    if b.is_proof {
                        continue;
                    }
                    b.covered = v.status == JudgeStatus::Met;
                    eprintln!(
                        "ac-judge [{}] {:?}: {}",
                        v.index + 1,
                        v.status,
                        &v.reason[..v.reason.len().min(120)]
                    );
                }
            }
            let missed = result
                .bullets
                .iter()
                .filter(|b| !b.covered && !b.waived)
                .count();
            result.status = if missed > 0 {
                CoverageStatus::Miss
            } else {
                CoverageStatus::Pass
            };
            ambient(
                "ac_judge_llm",
                vec![
                    ("pr_number", pr_number.to_string()),
                    ("gap_id", gap_id.to_string()),
                    ("bullets", result.bullets.len().to_string()),
                    ("missed", missed.to_string()),
                ],
            );
        }
    }
    Ok(result)
}

/// EFFECTIVE-367 (COTG): shared per-bullet scoring. Fetches the PR diff (in `repo`
/// if given) and scores each bullet via `check_coverage`. Infallible — a diff-fetch
/// failure yields an empty diff (bullets read as uncovered, i.e. fail-loud).
fn score_against_bullets(
    pr_number: u64,
    gap_id: String,
    raw_bullets: Vec<String>,
    trailer_text: String,
    repo: Option<&str>,
) -> AcCoverageResult {
    // Fetch diff (external repo via --repo when supplied).
    let diff = match repo {
        Some(r) => run_gh(&["pr", "diff", &pr_number.to_string(), "--repo", r]),
        None => run_gh(&["pr", "diff", &pr_number.to_string()]),
    }
    .unwrap_or_default();

    // Parse waivers (0-based index per spec)
    let waivers = parse_waivers(&trailer_text);

    // Evaluate each bullet
    let mut bullets = Vec::new();
    let mut any_miss = false;
    // PEER-VERI-08 (INFRA-3655): track proof-bullet misses separately —
    // these are the ones CHUMP_VERIFY_LIVE_BLOCKING can promote past the
    // advisory fail-open path below.
    let mut any_proof_miss = false;

    for (i, text) in raw_bullets.iter().enumerate() {
        // Check if waived (0-based index)
        let waiver = waivers.iter().find(|(idx, _)| *idx == i);
        if let Some((_, reason)) = waiver {
            ambient(
                "ac_coverage_waived",
                vec![
                    ("pr_number", pr_number.to_string()),
                    ("gap_id", gap_id.clone()),
                    ("bullet_index", i.to_string()),
                    ("reason", reason.clone()),
                ],
            );
            bullets.push(BulletResult {
                index: i,
                text: text.clone(),
                covered: true,
                waived: true,
                waive_reason: Some(reason.clone()),
                rules_hit: vec![],
                is_proof: is_proof_bullet(text),
                proof_detail: None,
            });
            continue;
        }

        // CREDIBLE-281: a proof/verification AC ("PROVEN-BY <live outcome>")
        // is NEVER scored by the diff-keyword rules (a–d) — a diff can only
        // prove code changed, not that the claimed live outcome happened.
        // Route it to the live-outcome check instead; that check fails
        // closed when the bullet names no mechanically-checkable target.
        let is_proof = is_proof_bullet(text);
        let (rules_hit, covered, proof_detail) = if is_proof {
            let (verified, detail) = check_live_outcome(text);
            (Vec::new(), verified, Some(detail))
        } else {
            let rules_hit = check_coverage(text, &diff, &trailer_text);
            let covered = !rules_hit.is_empty();
            (rules_hit, covered, None)
        };

        if !covered {
            any_miss = true;
            if is_proof {
                any_proof_miss = true;
            }
            let prefix = &text[..text.len().min(40)];
            ambient(
                if is_proof {
                    "ac_coverage_proof_miss"
                } else {
                    "ac_coverage_miss"
                },
                vec![
                    ("pr_number", pr_number.to_string()),
                    ("gap_id", gap_id.clone()),
                    ("bullet_index", i.to_string()),
                    ("bullet_text_prefix", prefix.to_string()),
                    ("detail", proof_detail.clone().unwrap_or_default()),
                ],
            );
        }

        bullets.push(BulletResult {
            index: i,
            text: text.clone(),
            covered,
            waived: false,
            waive_reason: None,
            rules_hit,
            is_proof,
            proof_detail,
        });
    }

    // Determine status
    let is_advisory = std::env::var("CHUMP_AC_GATE_ADVISORY").as_deref() == Ok("true");
    // PEER-VERI-08 (INFRA-3655) AC#2: an unproven live-outcome result BLOCKS
    // the close instead of being swallowed by the advisory fail-open path —
    // but only when the operator has ratcheted CHUMP_VERIFY_LIVE_BLOCKING on
    // (default off). Non-proof misses are untouched by this flag (AC#3).
    let live_blocking =
        any_proof_miss && std::env::var("CHUMP_VERIFY_LIVE_BLOCKING").as_deref() == Ok("1");
    let status = if any_miss {
        if live_blocking {
            CoverageStatus::Miss
        } else if is_advisory {
            CoverageStatus::Advisory
        } else {
            CoverageStatus::Miss
        }
    } else {
        CoverageStatus::Pass
    };
    if live_blocking {
        ambient(
            "ac_coverage_live_blocking",
            vec![
                ("pr_number", pr_number.to_string()),
                ("gap_id", gap_id.clone()),
            ],
        );
    }

    // Print miss list to stderr
    if any_miss {
        eprintln!("ac-coverage: uncovered AC bullets for {gap_id} on PR #{pr_number}:");
        for b in &bullets {
            if !b.covered && !b.waived {
                eprintln!("  [{}] {}", b.index, &b.text[..b.text.len().min(80)]);
            }
        }
    }

    AcCoverageResult {
        pr_number,
        gap_id: Some(gap_id),
        status,
        bullets,
    }
}

// ── EFFECTIVE-373 (COTG slice 2): the LLM AC judge ────────────────────────────
// The heuristic check_coverage above is a cheap keyword first-pass that can't tell
// "fixed the Stripe script but missed the join page" from "fixed everything". The LLM
// judge reads the actual diff against each criterion and returns MET/UNMET/PARTIAL with
// file:line reasoning — the REAL gate. It's an LLM call (~0 local CPU), so it's the
// affordable brain of the compute-aware local gate (EFFECTIVE-372).

/// Per-bullet judgement from the LLM AC judge.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum JudgeStatus {
    Met,
    Partial,
    Unmet,
}

#[derive(Debug, Clone)]
pub struct JudgeVerdict {
    pub index: usize,
    pub status: JudgeStatus,
    pub reason: String,
}

/// Parse the judge's per-criterion reply lines:
///   `BULLET <n>: MET|UNMET|PARTIAL - <reason>`
/// `n` is 1-based in the reply → 0-based `index`. Pure + unit-tested. Robust to
/// case, extra prose, and missing lines. A bullet with no parseable verdict is
/// simply absent from the result — the CALLER treats an un-judged criterion as NOT
/// proven met (fail-closed for the gate). CREDIBLE-207: this reasoning is durable
/// data, never swallowed.
pub(crate) fn parse_judge_verdicts(resp: &str, n_bullets: usize) -> Vec<JudgeVerdict> {
    let mut out: Vec<JudgeVerdict> = Vec::new();
    for line in resp.lines() {
        // FORMAT-AGNOSTIC (live opus emits all of: "BULLET 1: MET -", "1. MET -",
        // "1. BULLET 1: MET -"). Rather than anchor on a prefix, find the verdict
        // KEYWORD anywhere on the line, then the first in-range bullet number.
        let up = line.to_uppercase();
        // UNMET before MET: "UNMET" contains "MET" as a substring.
        let (status, kw): (JudgeStatus, &str) = if up.contains("UNMET") {
            (JudgeStatus::Unmet, "UNMET")
        } else if up.contains("PARTIAL") {
            (JudgeStatus::Partial, "PARTIAL")
        } else if up.contains("MET") {
            (JudgeStatus::Met, "MET")
        } else {
            continue;
        };
        let idx1 = match first_bullet_number(line, n_bullets) {
            Some(n) => n,
            None => continue,
        };
        // Reason = text after the (first) keyword occurrence.
        let kw_pos = up.find(kw).unwrap_or(0);
        let reason = line[(kw_pos + kw.len()).min(line.len())..]
            .trim_start_matches([' ', '-', ':', '—', '\t'])
            .trim()
            .to_string();
        out.retain(|v| v.index != idx1 - 1); // last write wins on a repeat
        out.push(JudgeVerdict {
            index: idx1 - 1,
            status,
            reason,
        });
    }
    out.sort_by_key(|v| v.index);
    out
}

/// First run of ASCII digits on the line that parses to a value in `1..=n_bullets`
/// (the criterion number). Ignores later numbers like `file.js:11` because the
/// bullet number leads the line.
fn first_bullet_number(line: &str, n_bullets: usize) -> Option<usize> {
    let bytes = line.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i].is_ascii_digit() {
            let start = i;
            while i < bytes.len() && bytes[i].is_ascii_digit() {
                i += 1;
            }
            if let Ok(n) = line[start..i].parse::<usize>() {
                if (1..=n_bullets).contains(&n) {
                    return Some(n);
                }
            }
        } else {
            i += 1;
        }
    }
    None
}

/// EFFECTIVE-373: judge the PR diff against ALL `bullets` in ONE `chump llm-complete`
/// call. Returns per-bullet verdicts, or `None` if the diff/model is unavailable or the
/// reply is unparseable (the caller falls back to the heuristic first-pass, then may
/// escalate). Judge model via `CHUMP_AC_JUDGE_MODEL` (default `opus` — the gate must be
/// trustworthy; free→Claude escalation is the caller's job).
pub(crate) fn llm_judge_ac(
    repo: Option<&str>,
    pr_number: u64,
    gap_title: &str,
    bullets: &[String],
) -> Option<Vec<JudgeVerdict>> {
    if bullets.is_empty() {
        return None;
    }
    let diff = match repo {
        Some(r) => run_gh(&["pr", "diff", &pr_number.to_string(), "--repo", r]),
        None => run_gh(&["pr", "diff", &pr_number.to_string()]),
    }
    .ok()?;
    if diff.trim().is_empty() {
        return None;
    }
    let ac_text = bullets
        .iter()
        .enumerate()
        .map(|(i, b)| format!("{}. {b}", i + 1))
        .collect::<Vec<_>>()
        .join("\n");
    let diff_trunc: String = diff.chars().take(60_000).collect();
    let prompt = format!(
        "You are a strict code reviewer deciding whether a PR satisfies a gap's acceptance \
         criteria.\nGap: {gap_title}\n\n\
         For EACH numbered criterion, judge whether the PR DIFF FULLY satisfies it — addressing \
         EVERY place the criterion applies, not just one instance. Be skeptical: a change that \
         fixes one occurrence but leaves another is PARTIAL, not MET; a criterion the diff never \
         touches is UNMET.\n\n\
         Reply with EXACTLY one line per criterion and nothing else:\n\
         BULLET <n>: MET|UNMET|PARTIAL - <=20-word reason with file:line evidence\n\n\
         === ACCEPTANCE CRITERIA ===\n{ac_text}\n\n\
         === PR DIFF ===\n{diff_trunc}\n"
    );
    let chump_bin = std::env::var("CHUMP_REAL_BINARY").unwrap_or_else(|_| "chump".to_string());
    let model = std::env::var("CHUMP_AC_JUDGE_MODEL").unwrap_or_else(|_| "opus".to_string());
    let max_tokens = (bullets.len() * 45 + 120).to_string();
    let mut child = Command::new(&chump_bin)
        .args([
            "llm-complete",
            "--model",
            &model,
            "--max-tokens",
            &max_tokens,
        ])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .ok()?;
    if let Some(mut si) = child.stdin.take() {
        use std::io::Write;
        let _ = si.write_all(prompt.as_bytes());
    }
    let out = child.wait_with_output().ok()?;
    let verdicts = parse_judge_verdicts(&String::from_utf8_lossy(&out.stdout), bullets.len());
    if verdicts.is_empty() {
        None
    } else {
        Some(verdicts)
    }
}

// ── minimal JSON helpers (no serde_json dep) ──────────────────────────────────

/// Extract a top-level JSON string field by name.
fn json_extract_string(json: &str, key: &str) -> Option<String> {
    let needle = format!(r#""{key}":"#);
    let pos = json.find(&needle)?;
    let rest = json[pos + needle.len()..].trim_start();
    if rest.starts_with('"') {
        // JSON string value
        let inner = &rest[1..];
        let mut out = String::new();
        let mut chars = inner.chars();
        loop {
            match chars.next()? {
                '"' => break,
                '\\' => match chars.next()? {
                    'n' => out.push('\n'),
                    'r' => out.push('\r'),
                    't' => out.push('\t'),
                    '"' => out.push('"'),
                    '\\' => out.push('\\'),
                    '/' => out.push('/'),
                    c => {
                        out.push('\\');
                        out.push(c);
                    }
                },
                c => out.push(c),
            }
        }
        Some(out)
    } else {
        None
    }
}

/// Extract `messageHeadline` + `messageBody` from each commit in the JSON array.
fn extract_commit_messages(json: &str) -> Vec<String> {
    let mut out = Vec::new();
    // Find "commits":[ and walk through objects
    let Some(start) = json.find(r#""commits":["#) else {
        return out;
    };
    let commits_section = &json[start..];
    // Simple heuristic: extract all messageHeadline and messageBody values
    let mut rest = commits_section;
    while let Some(pos) = rest.find(r#""messageHeadline":"#) {
        rest = &rest[pos + r#""messageHeadline":"#.len()..];
        if let Some(v) = extract_json_string_at(rest) {
            out.push(v.text);
            rest = &rest[v.consumed..];
        }
    }
    let mut rest2 = commits_section;
    while let Some(pos) = rest2.find(r#""messageBody":"#) {
        rest2 = &rest2[pos + r#""messageBody":"#.len()..];
        if let Some(v) = extract_json_string_at(rest2) {
            if !v.text.is_empty() {
                out.push(v.text);
            }
            rest2 = &rest2[v.consumed..];
        }
    }
    out
}

struct ExtractResult {
    text: String,
    consumed: usize,
}

fn extract_json_string_at(s: &str) -> Option<ExtractResult> {
    let s = s.trim_start();
    if !s.starts_with('"') {
        return None;
    }
    let inner = &s[1..];
    let mut out = String::new();
    let mut chars = inner.char_indices();
    let end_byte = loop {
        let (bi, c) = chars.next()?;
        match c {
            '"' => break bi + 1, // byte after closing quote in `inner`
            '\\' => {
                let (_bi2, c2) = chars.next()?;
                match c2 {
                    'n' => out.push('\n'),
                    'r' => out.push('\r'),
                    't' => out.push('\t'),
                    '"' => out.push('"'),
                    '\\' => out.push('\\'),
                    '/' => out.push('/'),
                    _ => {
                        out.push('\\');
                        out.push(c2);
                    }
                }
            }
            c => out.push(c),
        }
    };
    // consumed = 1 (opening quote) + end_byte (bytes consumed in inner)
    let consumed = 1 + end_byte;
    Some(ExtractResult {
        text: out,
        consumed,
    })
}

// ── EFFECTIVE-386: AC-writer ────────────────────────────────────────────────
// The AC-judge (Gate 4, EFFECTIVE-373) is only as good as the bullets it judges
// against: generic boilerplate ("fixed on live site", "works correctly") is
// unjudgeable, so a gap with vague AC silently passes the hard gate — the exact
// false-green COTG exists to kill. The AC-writer generates bullets that NAME a
// specific file/function/value AND an observable, independently-verifiable
// outcome. It is the binding INPUT that makes the hard gate meaningful, and the
// on-ramp that lets gap-less human PRs be judged on the same footing as agent work.

/// Pull `(title, description)` for a gap from canonical state.db via `chump gap show`.
pub(crate) fn gap_title_and_description(gap_id: &str) -> Result<(String, String), String> {
    let chump_bin = std::env::var("CHUMP_REAL_BINARY").unwrap_or_else(|_| "chump".to_string());
    let out = Command::new(&chump_bin)
        .args(["gap", "show", gap_id, "--json"])
        .output()
        .map_err(|e| format!("cannot run `{chump_bin} gap show {gap_id} --json`: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "`chump gap show {gap_id} --json` failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    let v: serde_json::Value = serde_json::from_slice(&out.stdout)
        .map_err(|e| format!("cannot parse `chump gap show {gap_id} --json`: {e}"))?;
    let title = v
        .get("title")
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .to_string();
    let desc = v
        .get("description")
        .and_then(|x| x.as_str())
        .unwrap_or("")
        .to_string();
    Ok((title, desc))
}

/// Build the AC-writer prompt: emit specific, testable, file/value-naming acceptance
/// bullets and BAN vague boilerplate. `context` is optional extra grounding (a PR
/// diff, related files) — pass "" when unavailable.
pub(crate) fn build_ac_writer_prompt(title: &str, description: &str, context: &str) -> String {
    let ctx_block = if context.trim().is_empty() {
        String::new()
    } else {
        format!("\nAdditional context (e.g. the diff or related code):\n{context}\n")
    };
    format!(
        "You are writing ACCEPTANCE CRITERIA for a software task — the checklist a reviewer uses \
         to decide whether the work is actually DONE.\n\n\
         Task title: {title}\n\
         Task description:\n{description}\n{ctx_block}\n\
         Write 2 to 5 acceptance criteria. RULES — each bullet MUST:\n\
         - name a SPECIFIC file, function, symbol, endpoint, flag, or value where it applies \
         (e.g. `src/foo.rs`'s `bar()`, the `/join` route, the `--apply` flag) — never a vague area;\n\
         - state an OBSERVABLE, independently-verifiable outcome (a named test passes, a value is \
         returned, a page renders X, a command exits 0) that someone could check WITHOUT trusting \
         the author;\n\
         - be satisfiable by THIS task alone (no dependency on future work).\n\
         BANNED: vague boilerplate — \"works correctly\", \"fixed on live site\", \"handles errors\", \
         \"is tested\" with no specifics. Those are unjudgeable and will be rejected.\n\n\
         Reply with EXACTLY one criterion per line, numbered, and NOTHING else:\n\
         1. <specific, testable criterion>\n\
         2. <...>\n"
    )
}

/// Parse the model's reply into clean bullet strings (strips `1.`/`1)`/`-`/`*`/`•` markers).
pub(crate) fn parse_ac_bullets(response: &str) -> Vec<String> {
    let mut out = Vec::new();
    for raw in response.lines() {
        let line = raw.trim();
        if line.is_empty() {
            continue;
        }
        // Only keep lines that carried a list marker (`1.`/`1)`/`-`/`*`/`•`). The
        // prompt demands one numbered criterion per line, so an unmarked line is
        // preamble/prose ("Here are the criteria:") — drop it, don't mistake it
        // for a bullet.
        if let Some(stripped) = strip_bullet_marker(line) {
            let s = stripped.trim();
            if s.len() >= 8 {
                out.push(s.to_string());
            }
        }
    }
    out
}

/// Strip a single leading list marker: `12.`, `12)`, `-`, `*`, or `•`. Returns
/// `None` when the line has no marker (so the caller can reject prose).
fn strip_bullet_marker(line: &str) -> Option<&str> {
    let t = line.trim_start();
    if let Some((num, tail)) = t.split_once(['.', ')']) {
        if !num.is_empty() && num.len() <= 3 && num.chars().all(|c| c.is_ascii_digit()) {
            return Some(tail.trim_start());
        }
    }
    for m in ['-', '*', '•'] {
        if let Some(rest) = t.strip_prefix(m) {
            return Some(rest.trim_start());
        }
    }
    None
}

/// Generate acceptance criteria for a gap via `chump llm-complete` (same rail as the
/// AC-judge). Returns `None` on any failure so the caller keeps existing AC. Model via
/// `CHUMP_AC_WRITER_MODEL`, falling back to `CHUMP_AC_JUDGE_MODEL`, then `opus`.
pub(crate) fn generate_ac(title: &str, description: &str, context: &str) -> Option<Vec<String>> {
    if title.trim().is_empty() {
        return None;
    }
    let prompt = build_ac_writer_prompt(title, description, context);
    let chump_bin = std::env::var("CHUMP_REAL_BINARY").unwrap_or_else(|_| "chump".to_string());
    let model = std::env::var("CHUMP_AC_WRITER_MODEL")
        .or_else(|_| std::env::var("CHUMP_AC_JUDGE_MODEL"))
        .unwrap_or_else(|_| "opus".to_string());
    let mut child = Command::new(&chump_bin)
        .args(["llm-complete", "--model", &model, "--max-tokens", "400"])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .ok()?;
    if let Some(mut si) = child.stdin.take() {
        use std::io::Write;
        let _ = si.write_all(prompt.as_bytes());
    }
    let out = child.wait_with_output().ok()?;
    let bullets = parse_ac_bullets(&String::from_utf8_lossy(&out.stdout));
    if bullets.is_empty() {
        None
    } else {
        Some(bullets)
    }
}

// ── EFFECTIVE-388: repo grounding for the AC-writer ─────────────────────────
// Without repo context the writer HALLUCINATES plausible-but-fake paths (on
// EFFECTIVE-372 it cited `src/lib/gate.rs` + `src/tests/*` that don't exist; the
// real file is `src/preflight.rs`). Grounding hands the model a ranked list of
// files that ACTUALLY exist in the repo, so its "specific file" anchors are real.

/// Stop-words that are never useful relevance tokens (English filler + a few
/// gap-boilerplate words). Kept tiny on purpose; the length/shape filter does most
/// of the work.
fn is_context_stopword(w: &str) -> bool {
    matches!(
        w,
        "the"
            | "and"
            | "for"
            | "with"
            | "that"
            | "this"
            | "from"
            | "make"
            | "gate"
            | "test"
            | "code"
            | "change"
            | "implement"
            | "implemented"
            | "relevant"
            | "should"
            | "when"
            | "into"
            | "than"
            | "then"
            | "path"
            | "file"
            | "files"
            | "demote"
            | "cloud"
            | "gaps"
    )
}

/// Pure: extract candidate file/symbol tokens from a gap's title + description —
/// things that plausibly name real code (contain `_`/`/`/a code extension, are
/// CamelCase, or are a long-ish lowercase word). Unit-tested so grounding's
/// relevance signal is verifiable without a repo.
pub(crate) fn extract_context_tokens(title: &str, description: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let text = format!("{title} {description}");
    for raw in text.split(|c: char| {
        c.is_whitespace()
            || matches!(
                c,
                ',' | ';' | '"' | '(' | ')' | '[' | ']' | '{' | '}' | ':' | '`'
            )
    }) {
        let t = raw.trim_matches(|c: char| matches!(c, '.' | '\'' | '<' | '>' | '?' | '!' | '#'));
        if t.len() < 4 || t.len() > 60 {
            continue;
        }
        let lower = t.to_ascii_lowercase();
        if is_context_stopword(&lower) {
            continue;
        }
        let has_underscore = t.contains('_');
        let has_slash = t.contains('/');
        let has_code_ext = [".rs", ".py", ".sh", ".ts", ".js", ".yaml", ".yml", ".toml"]
            .iter()
            .any(|e| t.ends_with(e));
        let is_camel =
            t.chars().any(|c| c.is_ascii_uppercase()) && t.chars().any(|c| c.is_ascii_lowercase());
        let is_longish_ident =
            t.len() >= 6 && t.chars().all(|c| c.is_ascii_alphanumeric() || c == '-');
        let codey = has_underscore || has_slash || has_code_ext || is_camel || is_longish_ident;
        if codey && !out.iter().any(|e: &String| e.eq_ignore_ascii_case(t)) {
            out.push(t.to_string());
        }
    }
    out.truncate(12);
    out
}

/// Pure: rank real repo `files` by how many `tokens` each path contains (case-
/// insensitive substring), most-relevant first, and cap at `limit`. Files matching
/// no token still fill remaining slots (stable order) so the model always sees a
/// real sample of the tree. Unit-tested.
pub(crate) fn rank_files_by_relevance(
    files: &[String],
    tokens: &[String],
    limit: usize,
) -> Vec<String> {
    let lc_tokens: Vec<String> = tokens.iter().map(|t| t.to_ascii_lowercase()).collect();
    let mut scored: Vec<(usize, usize, &String)> = files
        .iter()
        .enumerate()
        .map(|(i, f)| {
            let fl = f.to_ascii_lowercase();
            let score = lc_tokens.iter().filter(|t| fl.contains(t.as_str())).count();
            (score, i, f)
        })
        .collect();
    // Higher score first; ties keep original order (stable via the index).
    scored.sort_by(|a, b| b.0.cmp(&a.0).then(a.1.cmp(&b.1)));
    scored
        .into_iter()
        .take(limit)
        .map(|(_, _, f)| f.clone())
        .collect()
}

/// Build a grounding context string for a gap: the real repo files most relevant
/// to its title/description, so the writer anchors AC on paths that exist. Returns
/// "" when the repo file list is unavailable (writer then runs ungrounded — no
/// worse than before). Reads tracked files via `git ls-files` in the CWD repo.
fn gather_repo_context(title: &str, description: &str) -> String {
    let out = match Command::new("git").args(["ls-files"]).output() {
        Ok(o) if o.status.success() => o,
        _ => return String::new(),
    };
    let source_exts = [
        ".rs", ".py", ".sh", ".ts", ".js", ".tsx", ".jsx", ".yaml", ".yml", ".toml", ".md", ".sql",
    ];
    let files: Vec<String> = String::from_utf8_lossy(&out.stdout)
        .lines()
        .filter(|l| source_exts.iter().any(|e| l.ends_with(e)))
        .filter(|l| !l.contains("/fixtures/") && !l.contains("/testdata/"))
        .map(|l| l.to_string())
        .collect();
    if files.is_empty() {
        return String::new();
    }
    let tokens = extract_context_tokens(title, description);
    // Content matches (`git grep -l`) for the most distinctive tokens rank HIGHEST —
    // filename matching alone misses the common case where the gap says "gate" but
    // the code lives in `src/preflight.rs`. Bounded: top few tokens, capped hits,
    // errors ignored (grounding degrades to filename ranking).
    let mut content_hits: Vec<String> = Vec::new();
    for tok in tokens.iter().filter(|t| t.len() >= 5).take(4) {
        if let Ok(o) = Command::new("git")
            .args(["grep", "-l", "-i", "-F", "--", tok])
            .output()
        {
            if o.status.success() {
                for l in String::from_utf8_lossy(&o.stdout).lines().take(8) {
                    if source_exts.iter().any(|e| l.ends_with(e))
                        && !content_hits.iter().any(|h| h == l)
                    {
                        content_hits.push(l.to_string());
                    }
                }
            }
        }
    }
    // Merge: content matches first (most relevant), then filename-ranked fill.
    let ranked_by_name = rank_files_by_relevance(&files, &tokens, 40);
    let mut ranked: Vec<String> = content_hits;
    for f in ranked_by_name {
        if ranked.len() >= 40 {
            break;
        }
        if !ranked.iter().any(|r| r == &f) {
            ranked.push(f);
        }
    }
    let list = ranked
        .iter()
        .map(|f| format!("- {f}"))
        .collect::<Vec<_>>()
        .join("\n");
    format!(
        "REAL files that exist in this repository (reference ONLY paths from this list, \
         or a NEW path the task explicitly creates — do NOT invent file names):\n{list}"
    )
}

/// EFFECTIVE-388: generate AC for a gap WITH repo grounding — the CLI entry point.
/// Loads the gap's title/description, gathers real repo files as context, and calls
/// `generate_ac` so the model names paths that exist. Falls back to ungrounded
/// generation if the repo listing is unavailable.
pub fn generate_ac_for_gap(gap_id: &str) -> Result<Vec<String>, String> {
    let (title, desc) = gap_title_and_description(gap_id)?;
    let context = gather_repo_context(&title, &desc);
    generate_ac(&title, &desc, &context)
        .ok_or_else(|| "AC generation failed (empty title or LLM unavailable)".to_string())
}

/// EFFECTIVE-388: split a bullet into the `path/like/tokens.ext` it cites (tokens
/// containing a `/` and a dotted extension, or a bare `*.rs`-style name). Used to
/// warn when generated AC references a path that does not exist. Pure — unit-tested.
pub fn cited_paths(bullet: &str) -> Vec<String> {
    let mut out = Vec::new();
    for raw in bullet
        .split(|c: char| c.is_whitespace() || matches!(c, '`' | ',' | ';' | '(' | ')' | '"' | '\''))
    {
        // Strip angle brackets and TRAILING sentence punctuation only — keep a
        // LEADING dot so dotpaths like `.chump/x` / `.github/y` survive (stripping
        // it wrongly flagged real dotfiles as non-existent).
        let t = raw
            .trim_matches(|c: char| matches!(c, '<' | '>'))
            .trim_end_matches(|c: char| matches!(c, '.' | ':'));
        let looks_like_path = (t.contains('/')
            && t.rsplit('/')
                .next()
                .map(|f| f.contains('.'))
                .unwrap_or(false))
            || [".rs", ".py", ".sh", ".ts", ".js", ".yaml", ".yml", ".toml"]
                .iter()
                .any(|e| t.ends_with(e));
        if looks_like_path && t.len() >= 4 && !out.iter().any(|e: &String| e == t) {
            out.push(t.to_string());
        }
    }
    out
}

// ── unit tests ────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    /// CREDIBLE-281 tests mutate `CHUMP_AMBIENT_LOG` (process-global env) —
    /// serialize them so parallel test threads can't race each other's
    /// set/remove.
    static AMBIENT_ENV_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn effective388_extract_context_tokens_keeps_codey_drops_filler() {
        let toks = extract_context_tokens(
            "wire the join_page route",
            "render src/preflight.rs and the CamelCase Widget; the gate should work",
        );
        // Codey tokens kept.
        assert!(toks.iter().any(|t| t == "join_page"));
        assert!(toks.iter().any(|t| t == "src/preflight.rs"));
        assert!(toks.iter().any(|t| t == "CamelCase" || t == "Widget"));
        // Filler / stopwords dropped.
        assert!(!toks
            .iter()
            .any(|t| t == "the" || t == "gate" || t == "work" || t == "should"));
    }

    #[test]
    fn effective388_rank_files_puts_token_matches_first() {
        let files = vec![
            "src/unrelated.rs".to_string(),
            "src/preflight.rs".to_string(),
            "docs/x.md".to_string(),
            "src/join_page.rs".to_string(),
        ];
        let tokens = vec!["preflight".to_string(), "join_page".to_string()];
        let ranked = rank_files_by_relevance(&files, &tokens, 3);
        assert_eq!(ranked.len(), 3);
        // The two token-matching files rank ahead of the non-matching ones.
        assert!(ranked.contains(&"src/preflight.rs".to_string()));
        assert!(ranked.contains(&"src/join_page.rs".to_string()));
        assert_eq!(&ranked[2], "src/unrelated.rs"); // first non-match fills the last slot
    }

    #[test]
    fn effective388_cited_paths_finds_real_looking_paths() {
        let paths =
            cited_paths("The `src/preflight.rs` gate and test_gate.rs must pass, see /join route");
        assert!(paths.iter().any(|p| p == "src/preflight.rs"));
        assert!(paths.iter().any(|p| p == "test_gate.rs"));
        // "/join" has no extension on its final segment → not treated as a file path.
        assert!(!paths.iter().any(|p| p == "/join"));
    }

    #[test]
    fn effective386_parse_ac_bullets_strips_markers_and_prose() {
        let reply = "Here are the criteria:\n\
                     1. `src/join.rs`'s render_invite() returns the code from the URL path\n\
                     2) A logged-out visitor hitting /join is redirected to /login (302)\n\
                     - The `--apply` flag persists AC via `chump gap set` and exits 0\n\
                     * cargo test join_page_renders passes\n\
                     \n\
                     ok";
        let bullets = parse_ac_bullets(reply);
        assert_eq!(
            bullets.len(),
            4,
            "4 real bullets, prose/blank dropped: {bullets:?}"
        );
        assert_eq!(
            bullets[0],
            "`src/join.rs`'s render_invite() returns the code from the URL path"
        );
        assert!(bullets[1].starts_with("A logged-out visitor"));
        assert!(bullets[2].starts_with("The `--apply` flag"));
        assert!(bullets[3].starts_with("cargo test"));
        // "ok" (len 2, no marker) is dropped by the min-length guard.
        assert!(!bullets.iter().any(|b| b == "ok"));
    }

    #[test]
    fn effective386_ac_writer_prompt_demands_specifics_bans_boilerplate() {
        let p = build_ac_writer_prompt("wire the join page", "render the invite code", "");
        // Carries the task.
        assert!(p.contains("wire the join page"));
        // Demands a specific file/function/value anchor + observable outcome.
        assert!(p.contains("SPECIFIC file"));
        assert!(p.contains("OBSERVABLE"));
        assert!(p.contains("WITHOUT trusting"));
        // Explicitly bans the boilerplate class the AC-judge can't catch.
        assert!(p.contains("fixed on live site"));
        assert!(p.contains("BANNED"));
        // Optional context block is omitted when empty.
        assert!(!p.contains("Additional context"));
        let p2 = build_ac_writer_prompt("t", "d", "diff --git a/x b/x");
        assert!(p2.contains("Additional context"));
    }

    #[test]
    fn test_title_parser_extracts_gap_id() {
        assert_eq!(
            parse_gap_id("INFRA-1234: add something"),
            Some("INFRA-1234".to_string())
        );
        assert_eq!(
            parse_gap_id("feat(INFRA-9001): add foo bar"),
            Some("INFRA-9001".to_string())
        );
        assert_eq!(
            parse_gap_id("FLEET-007: scale test"),
            Some("FLEET-007".to_string())
        );
    }

    #[test]
    fn test_title_parser_no_gap_ref() {
        assert_eq!(parse_gap_id("fix: hotfix PR"), None);
        assert_eq!(parse_gap_id("chore: docs cleanup"), None);
        assert_eq!(parse_gap_id(""), None);
    }

    #[test]
    fn test_coverage_rule_a_file_path() {
        let bullet = "src/pr_ac_coverage.rs must exist and implement run()";
        let diff = "+++ b/src/pr_ac_coverage.rs\n+pub fn run() {}\n";
        assert!(rule_a(bullet, diff), "Rule (a) should match file path");
    }

    #[test]
    fn test_coverage_rule_b_symbol() {
        let bullet = "emit kind=ac_coverage_miss to ambient";
        let diff = "+    ac_coverage_miss_event();\n";
        assert!(
            rule_b(bullet, diff),
            "Rule (b) should match symbol ac_coverage_miss"
        );
    }

    #[test]
    fn test_coverage_rule_c_closes_ac_trailer() {
        let bullet = "File src/pr_ac_coverage.rs must exist and implement run()";
        let commit_text = "Closes-AC: File src/pr_ac_coverage.rs must exist and implement run()";
        assert!(
            rule_c(bullet, commit_text),
            "Rule (c) should match Closes-AC trailer"
        );
    }

    #[test]
    fn test_coverage_rule_c_accepts_realistic_short_pointer_trailer() {
        // CREDIBLE-180: real merged commits in this repo's own history use
        // short pointer trailers, not the full bullet text -- e.g.
        // "Closes-AC: scripts/ci/test-pr-ac-coverage.sh" against a longer
        // bullet describing that same script. The half-length-coverage floor
        // must still accept this shape; only much-shorter, low-effort
        // prefix-echoes (see the redteam control below) should fail.
        let bullet = "Smoke test scripts/ci/test-ac-coverage-gate.sh exercises pass and miss paths";
        let commit_text =
            "Closes-AC: Smoke test scripts/ci/test-ac-coverage-gate.sh exercises pass";
        assert!(
            rule_c(bullet, commit_text),
            "Rule (c) should still accept a substantial partial-bullet trailer"
        );
    }

    #[test]
    fn test_coverage_rule_c_rejects_short_prefix_echo() {
        // CREDIBLE-180: the exact exploit CREDIBLE-177's redteam fixture
        // found -- echoing just the first few words of a much longer bullet
        // as the trailer, with zero real diff evidence -- must now fail.
        let bullet = "the fixture set runs against the live judgment organ on the same schedule as ChumpBench nightly regression, not a separate cadence";
        let commit_text = "Closes-AC: the fixture set runs against";
        assert!(
            !rule_c(bullet, commit_text),
            "Rule (c) must reject a short echo of only the bullet's opening words"
        );
    }

    #[test]
    fn test_coverage_rule_d_test_file_keyword() {
        let bullet = "Shell wrapper scripts/ci/test-pr-ac-coverage.sh must be a 3-line exec";
        let diff = concat!(
            "+++ b/scripts/ci/test-pr-ac-coverage.sh\n",
            "+exec chump pr ac-coverage \"$@\"\n",
        );
        assert!(
            rule_d(bullet, diff),
            "Rule (d) should match test file keyword 'exec'"
        );
    }

    // ── CREDIBLE-281: proof-AC gate ─────────────────────────────────────────

    #[test]
    fn credible281_is_proof_bullet_detects_markers() {
        assert!(is_proof_bullet(
            "a gap whose AC says PROVEN-BY <live outcome> cannot reach done"
        ));
        assert!(is_proof_bullet(
            "PROVEN by the scorecard organ recovering to green"
        ));
        assert!(is_proof_bullet("proof: endpoint responds 200"));
        assert!(!is_proof_bullet(
            "src/pr_ac_coverage.rs must exist and implement run()"
        ));
    }

    #[test]
    fn credible281_infra3598_class_bullet_is_unverifiable_and_fails_closed() {
        // The exact shape of INFRA-3598's real AC bullet: a proof claim that
        // names an outcome ("the scorecard organ recovering to green") but no
        // literal, mechanically-checkable target. Rules a-d could keyword-match
        // "scorecard organ" against an unrelated diff and rubber-stamp it --
        // that is precisely the false-done this gate exists to reject. The
        // live-outcome check must fail closed instead of passing on vibes.
        let bullet =
            "PROVEN by the scorecard organ recovering to green from its already-merged fix once this lands";
        assert!(is_proof_bullet(bullet));
        let (verified, detail) = check_live_outcome(bullet);
        assert!(
            !verified,
            "an unverifiable proof claim must fail closed, not pass: {detail}"
        );
    }

    #[test]
    fn credible281_proof_bullet_ignores_diff_keyword_match() {
        // Even when the diff happens to contain every keyword from the proof
        // bullet, a proof AC is not satisfied by check_coverage's rules --
        // only check_live_outcome decides it, and here it fails closed.
        let bullet = "PROVEN-BY the scorecard organ recovering to green";
        let diff = "+++ b/src/whatever.rs\n+let msg = \"scorecard organ recovering to green\";\n";
        let rules_hit = check_coverage(bullet, diff, "");
        assert!(
            !rules_hit.is_empty(),
            "sanity: the diff DOES keyword-match via rule_b, proving the old \
             behavior would have passed this"
        );
        let (verified, _) = check_live_outcome(bullet);
        assert!(
            !verified,
            "proof bullet must not be satisfied merely because the diff echoes its words"
        );
    }

    #[test]
    fn credible281_proof_bullet_verified_via_named_ambient_event() {
        let _guard = AMBIENT_ENV_LOCK.lock().unwrap();
        let dir = std::env::temp_dir().join(format!(
            "credible281-ambient-{}-{}",
            std::process::id(),
            line!()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let log_path = dir.join("ambient.jsonl");
        std::fs::write(
            &log_path,
            "{\"ts\":\"now\",\"kind\":\"deploy_audit_emitted\",\"gap_id\":\"INFRA-3598\"}\n",
        )
        .unwrap();
        std::env::set_var("CHUMP_AMBIENT_LOG", &log_path);
        let bullet = "PROVEN-BY an emitted kind=deploy_audit_emitted event the board can verify";
        let (verified, detail) = check_live_outcome(bullet);
        std::env::remove_var("CHUMP_AMBIENT_LOG");
        let _ = std::fs::remove_dir_all(&dir);
        assert!(
            verified,
            "named ambient event present should verify: {detail}"
        );
    }

    #[test]
    fn credible281_proof_bullet_unverified_when_named_event_absent() {
        let _guard = AMBIENT_ENV_LOCK.lock().unwrap();
        let dir = std::env::temp_dir().join(format!(
            "credible281-ambient-absent-{}-{}",
            std::process::id(),
            line!()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let log_path = dir.join("ambient.jsonl");
        std::fs::write(&log_path, "{\"ts\":\"now\",\"kind\":\"unrelated_event\"}\n").unwrap();
        std::env::set_var("CHUMP_AMBIENT_LOG", &log_path);
        let bullet = "PROVEN-BY an emitted kind=deploy_audit_emitted event the board can verify";
        let (verified, _) = check_live_outcome(bullet);
        std::env::remove_var("CHUMP_AMBIENT_LOG");
        let _ = std::fs::remove_dir_all(&dir);
        assert!(!verified, "absent named event must not verify");
    }

    #[test]
    fn credible281_find_systemd_unit_token_extracts_literal_unit() {
        let bullet = "PROVEN-BY chump-sla-scorecard.service reaching active state";
        assert_eq!(
            find_systemd_unit_token(bullet),
            Some("chump-sla-scorecard.service".to_string())
        );
        assert_eq!(
            find_systemd_unit_token("PROVEN-BY the scorecard organ recovering to green"),
            None
        );
    }

    #[test]
    fn credible281_llm_judge_cannot_override_proof_bullet_verdict() {
        // score_against_bullets marks a proof bullet uncovered (fail-closed);
        // simulate the LLM-judge override loop and confirm the `is_proof`
        // guard keeps it from flipping the verdict to covered.
        let mut b = BulletResult {
            index: 0,
            text: "PROVEN-BY the scorecard organ recovering to green".to_string(),
            covered: false,
            waived: false,
            waive_reason: None,
            rules_hit: vec![],
            is_proof: true,
            proof_detail: Some("unverifiable".to_string()),
        };
        let verdict_says_met = true;
        if !b.is_proof {
            b.covered = verdict_says_met;
        }
        assert!(
            !b.covered,
            "LLM judge must not override a proof bullet's live-outcome verdict"
        );
    }

    // ── PEER-VERI-08 (INFRA-3655): systemic proof-AC synthesis + blocking ──

    #[test]
    fn peerveri08_service_touching_diff_gets_injected_proof_ac() {
        let diff = concat!(
            "diff --git a/systemd/chump-worker.service b/systemd/chump-worker.service\n",
            "+++ b/systemd/chump-worker.service\n",
            "+[Unit]\n",
            "+Description=chump worker\n",
        );
        let injected = maybe_inject_proof_ac(diff, &[]);
        assert!(injected.is_some(), "service-unit diff must get a proof AC");
        let bullet = injected.unwrap();
        assert!(is_proof_bullet(&bullet));
        assert_eq!(
            find_systemd_unit_token(&bullet),
            Some("chump-worker.service".to_string()),
            "injected bullet must name the concrete unit check_live_outcome can parse: {bullet}"
        );
    }

    #[test]
    fn peerveri08_docs_only_diff_gets_no_injected_proof_ac() {
        let diff = "+++ b/docs/process/FOO.md\n+some docs text\n";
        assert!(
            maybe_inject_proof_ac(diff, &[]).is_none(),
            "docs-only diff must not get a proof AC injected"
        );
    }

    #[test]
    fn peerveri08_existing_proof_bullet_is_not_duplicated() {
        let diff = concat!(
            "diff --git a/systemd/chump-worker.service b/systemd/chump-worker.service\n",
            "+++ b/systemd/chump-worker.service\n",
            "+[Unit]\n",
        );
        let existing = vec!["PROVEN-BY chump-worker.service already covers this".to_string()];
        assert!(
            maybe_inject_proof_ac(diff, &existing).is_none(),
            "a diff that already carries a proof bullet must not get a second one injected"
        );
    }

    #[test]
    fn peerveri08_install_script_diff_with_no_derivable_target_gets_no_injection() {
        // AC#3: fail-open when no concrete, check_live_outcome-parseable
        // target can be derived, even though the surface (install script)
        // matched.
        let diff = "+++ b/scripts/setup/install-foo.sh\n+echo hello\n";
        assert!(maybe_inject_proof_ac(diff, &[]).is_none());
    }

    #[test]
    fn peerveri08_live_blocking_flag_promotes_proof_miss_past_advisory() {
        let _guard = AMBIENT_ENV_LOCK.lock().unwrap();
        std::env::set_var("CHUMP_AC_GATE_ADVISORY", "true");
        std::env::set_var("CHUMP_VERIFY_LIVE_BLOCKING", "1");
        let bullet =
            "PROVEN-BY chump-nonexistent-unit-xyz123.service reaching active state".to_string();
        let result = score_against_bullets(
            1,
            "INFRA-TEST".to_string(),
            vec![bullet],
            String::new(),
            None,
        );
        std::env::remove_var("CHUMP_AC_GATE_ADVISORY");
        std::env::remove_var("CHUMP_VERIFY_LIVE_BLOCKING");
        assert_eq!(
            result.status,
            CoverageStatus::Miss,
            "an inactive-unit proof AC must BLOCK (Miss) when CHUMP_VERIFY_LIVE_BLOCKING=1, \
             even though CHUMP_AC_GATE_ADVISORY=true would otherwise fail it open"
        );
    }

    #[test]
    fn peerveri08_live_blocking_flag_off_keeps_advisory_fail_open() {
        let _guard = AMBIENT_ENV_LOCK.lock().unwrap();
        std::env::set_var("CHUMP_AC_GATE_ADVISORY", "true");
        std::env::remove_var("CHUMP_VERIFY_LIVE_BLOCKING");
        let bullet =
            "PROVEN-BY chump-nonexistent-unit-xyz123.service reaching active state".to_string();
        let result = score_against_bullets(
            1,
            "INFRA-TEST".to_string(),
            vec![bullet],
            String::new(),
            None,
        );
        std::env::remove_var("CHUMP_AC_GATE_ADVISORY");
        assert_eq!(
            result.status,
            CoverageStatus::Advisory,
            "with CHUMP_VERIFY_LIVE_BLOCKING unset (default off), advisory mode must still fail open"
        );
    }

    #[test]
    fn test_waiver_parsed() {
        let body = "Some PR body text.\nAC-Coverage-Waive: 0: legacy path\nOther stuff.";
        let waivers = parse_waivers(body);
        assert_eq!(waivers.len(), 1);
        assert_eq!(waivers[0].0, 0);
        assert_eq!(waivers[0].1, "legacy path");
    }

    #[test]
    fn test_waiver_multiple() {
        let body = "AC-Coverage-Waive: 0: legacy\nAC-Coverage-Waive: 1: not applicable";
        let waivers = parse_waivers(body);
        assert_eq!(waivers.len(), 2);
        assert_eq!(waivers[1].0, 1);
        assert_eq!(waivers[1].1, "not applicable");
    }

    #[test]
    fn test_extract_keywords_skips_common() {
        let kws = extract_keywords("Add the file path with some test");
        // "some", "with", "test", "the", "file", "path", "Add" (3 chars) should be skipped
        // only words 4+ chars and not common
        assert!(!kws.iter().any(|k| k == "the" || k == "with" || k == "some"));
    }

    #[test]
    fn test_render_json_pass() {
        let result = AcCoverageResult {
            pr_number: 42,
            gap_id: Some("INFRA-1541".to_string()),
            status: CoverageStatus::Pass,
            bullets: vec![],
        };
        let json = render_json(&result);
        assert!(json.contains(r#""status":"pass""#));
        assert!(json.contains(r#""pr_number":42"#));
        assert!(json.contains(r#""gap_id":"INFRA-1541""#));
    }

    #[test]
    fn confidence_scales_with_ac_coverage() {
        // EFFECTIVE-333: the judgment score rises monotonically with the
        // covered-bullet fraction (bare pass/miss → a calibrated 0..1 score).
        let mk = |flags: &[bool]| AcCoverageResult {
            pr_number: 1,
            gap_id: Some("X-1".to_string()),
            status: CoverageStatus::Miss,
            bullets: flags
                .iter()
                .enumerate()
                .map(|(i, &c)| BulletResult {
                    index: i,
                    text: format!("bullet {i}"),
                    covered: c,
                    waived: false,
                    waive_reason: None,
                    rules_hit: vec![],
                    is_proof: false,
                    proof_detail: None,
                })
                .collect(),
        };
        let none = mk(&[false, false]).confidence();
        let half = mk(&[true, false]).confidence();
        let all = mk(&[true, true]).confidence();
        assert!(
            none < half && half < all,
            "confidence must rise with AC coverage: {none} < {half} < {all}"
        );
        assert!((0.0..=1.0).contains(&all), "confidence in 0..=1, got {all}");
        // A no-criteria pass is fully satisfied; a disabled result can't be judged.
        let no_ac_pass = AcCoverageResult {
            pr_number: 1,
            gap_id: None,
            status: CoverageStatus::Pass,
            bullets: vec![],
        };
        assert_eq!(no_ac_pass.confidence(), 1.0);
        let disabled = AcCoverageResult {
            status: CoverageStatus::Disabled,
            ..no_ac_pass
        };
        assert_eq!(disabled.confidence(), 0.5);
    }
}

// ── red-team fixtures (CREDIBLE-177, hardened by CREDIBLE-180) ──────────────
//
// Known-bad submissions exercised directly against the live judgment organ
// (`check_coverage`, the private function above). Each fixture's
// `currently_covered` documents check_coverage's REAL, empirically-verified
// behavior -- not an assumed or aspirational one. Verified by running each
// fixture against `check_coverage` before writing the assertion, both for
// the original CREDIBLE-177 finding and again after CREDIBLE-180's fix.
//
// History: CREDIBLE-177 (2026-07-30) found the first three categories (the
// exact three named in this gap's acceptance criteria) CONFIRMED CURRENTLY
// GAMEABLE -- rule (b) counted keywords inside comments, rule (c) accepted
// a loose Closes-AC prefix, rule (d) counted comment-only test-file lines.
// CREDIBLE-180 (same day) hardened all three rules against exactly those
// fixtures; `currently_covered` below reflects the POST-hardening result.
// If any of the three flips back to `true` in the future, that is a real
// verifier regression, not the original known finding recurring.
#[cfg(test)]
mod redteam {
    use super::*;

    struct Fixture {
        name: &'static str,
        category: &'static str,
        bullet: &'static str,
        diff: &'static str,
        commit_text: &'static str,
        /// Empirically-verified current check_coverage() outcome (non-empty rules_hit).
        currently_covered: bool,
    }

    fn fixtures() -> Vec<Fixture> {
        vec![
            Fixture {
                name: "stub_passes_as_done",
                category: "stub-passes-as-done",
                bullet: "emit kind=capability_drift_detected to ambient.jsonl when a bucketless cluster crosses the LOC floor",
                diff: concat!(
                    "+++ b/src/capability_drift.rs\n",
                    "+// TODO: emit kind=capability_drift_detected to ambient.jsonl when a bucketless cluster crosses the LOC floor\n",
                    "+fn scan() {}\n",
                ),
                commit_text: "",
                // CREDIBLE-180: FIXED — rule (b) now skips comment-only added lines,
                // so the TODO comment's own words no longer count as coverage.
                currently_covered: false,
            },
            Fixture {
                name: "meaningless_test",
                category: "meaningless-test",
                bullet: "test: seeding a deliberately-broken build causes a known-bad fixture to incorrectly pass",
                diff: concat!(
                    "+++ b/scripts/ci/test-redteam.sh\n",
                    "+#!/bin/bash\n",
                    "+# deliberately-broken build causes a known-bad fixture to incorrectly pass\n",
                    "+exit 0\n",
                ),
                commit_text: "",
                // CREDIBLE-180: FIXED — rules (b)+(d) now skip comment-only added lines,
                // so a no-op test's comment restating the bullet no longer counts.
                currently_covered: false,
            },
            Fixture {
                name: "dod_unmet_but_ci_green",
                category: "dod-unmet-ci-green",
                bullet: "the fixture set runs against the live judgment organ on the same schedule as ChumpBench nightly regression, not a separate cadence",
                diff: "+++ b/README.md\n+typo fix\n",
                commit_text: "Closes-AC: the fixture set runs against",
                // CREDIBLE-180: FIXED — rule (c) now requires an exact Closes-AC match,
                // so a loose prefix with zero real diff no longer counts.
                currently_covered: false,
            },
            Fixture {
                name: "genuinely_covered_baseline",
                category: "control-positive",
                bullet: "src/pr_ac_coverage.rs must implement check_coverage",
                diff: concat!(
                    "+++ b/src/pr_ac_coverage.rs\n",
                    "+fn check_coverage(bullet: &str, diff: &str, commit_text: &str) -> Vec<u8> { Vec::new() }\n",
                ),
                commit_text: "",
                // control: a real, on-topic diff touching the named file should pass.
                currently_covered: true,
            },
            Fixture {
                name: "genuinely_uncovered_baseline",
                category: "control-negative",
                bullet: "the desktop Tauri shell must render a native macOS menu bar with a Quit item",
                diff: "+++ b/docs/strategy/UNRELATED_TOPIC.md\n+some unrelated prose about pricing\n",
                commit_text: "chore: fix typo",
                // control: a totally unrelated diff must NOT be judged as covering this bullet.
                currently_covered: false,
            },
        ]
    }

    #[test]
    fn known_bad_fixtures_match_documented_baseline() {
        // The credibility half of the suite: prove the checked-in fixtures
        // are an accurate, CURRENT snapshot of check_coverage's real
        // behavior, not stale assumptions. A failure here means either
        // check_coverage's rules changed (update the fixture + evaluate
        // whether the drift is a hardening win or a further regression) or
        // a fixture is wrong -- either way it should never fail silently.
        let mut mismatches = Vec::new();
        for f in fixtures() {
            let hits = check_coverage(f.bullet, f.diff, f.commit_text);
            let covered = !hits.is_empty();
            if covered != f.currently_covered {
                mismatches.push(format!(
                    "{} ({}): expected currently_covered={} got covered={} (rules_hit={:?})",
                    f.name, f.category, f.currently_covered, covered, hits
                ));
            }
        }
        assert!(
            mismatches.is_empty(),
            "judgment-organ redteam: baseline drift detected -- {}",
            mismatches.join("; ")
        );
    }

    #[test]
    fn suite_has_teeth_against_an_always_permissive_checker() {
        // AC4: prove the fixture set actually discriminates rather than
        // trivially always-passing. Simulate a deliberately-broken judgment
        // organ (one that rubber-stamps every bullet as covered by rule a)
        // and show the control-negative fixture -- which the REAL checker
        // correctly rejects -- would incorrectly pass under it.
        fn deliberately_broken_check_coverage(
            _bullet: &str,
            _diff: &str,
            _commit_text: &str,
        ) -> Vec<u8> {
            vec![1] // always "covered by rule (a)", no matter what
        }

        let control_negative = fixtures()
            .into_iter()
            .find(|f| f.name == "genuinely_uncovered_baseline")
            .expect("control-negative fixture must exist");

        let real_result = check_coverage(
            control_negative.bullet,
            control_negative.diff,
            control_negative.commit_text,
        );
        let broken_result = deliberately_broken_check_coverage(
            control_negative.bullet,
            control_negative.diff,
            control_negative.commit_text,
        );

        assert!(
            real_result.is_empty(),
            "sanity: the real checker should currently reject the control-negative fixture"
        );
        assert!(
            !broken_result.is_empty(),
            "seeded deliberately-broken checker did not incorrectly pass the fixture -- test setup is wrong"
        );
        // The divergence itself is the proof: same fixture, real checker
        // says Miss, broken checker says Pass. A redteam suite that could
        // not produce this divergence would have no discriminating power.
    }

    #[test]
    fn effective367_run_with_ac_empty_bullets_is_pass_no_network() {
        // EFFECTIVE-367: run_with_ac short-circuits on empty AC BEFORE any gh call,
        // so it's safe to run offline. Empty bullets ⇒ nothing to check ⇒ Pass/Disabled
        // (never NoGapRef), and the gap_id is carried through for attribution. This is
        // the foundation guarantee: the caller's AC is honored, not re-derived from the PR.
        let r = run_with_ac("repairman29/pvc", 999_999, "PRODUCT-145", &[])
            .expect("empty-bullets path is infallible and makes no network call");
        assert_eq!(r.gap_id.as_deref(), Some("PRODUCT-145"));
        assert!(r.bullets.is_empty(), "empty AC ⇒ no bullets scored");
        assert!(
            matches!(r.status, CoverageStatus::Pass | CoverageStatus::Disabled),
            "empty AC must be Pass (or Disabled if the gate env is off) — NEVER NoGapRef, got {:?}",
            r.status
        );
    }

    #[test]
    fn effective373_parse_judge_verdicts() {
        // EFFECTIVE-373: the judge's per-bullet reply parses to MET/UNMET/PARTIAL with
        // reasoning preserved (CREDIBLE-207 — never swallowed). Models the exact pvc#2
        // shape: Stripe-script fixed (MET) but join-page missed (UNMET).
        // Mix of the THREE real formats live opus emitted (2026-08-07): "BULLET n:",
        // "n. BULLET n:", "n. STATUS". Format-agnostic parse must handle all.
        let resp = "1. BULLET 1: MET - fixed FRIEND_CENTS in create-supporting-member-payment-links.js:11\n\
                    BULLET 2: UNMET - join/page.tsx:76 not touched, still Friend ($49/yr)\n\
                    (some prose the model added between lines)\n\
                    3. PARTIAL - membership.ts updated but about page unchecked\n";
        let v = parse_judge_verdicts(resp, 3);
        assert_eq!(
            v.len(),
            3,
            "three criteria parsed across mixed formats, got {v:?}"
        );
        assert_eq!(v[0].status, JudgeStatus::Met);
        assert_eq!(v[1].status, JudgeStatus::Unmet);
        assert!(
            v[1].reason.contains("join/page.tsx:76"),
            "reasoning preserved (CREDIBLE-207), got: {}",
            v[1].reason
        );
        assert_eq!(v[2].status, JudgeStatus::Partial);
        // UNMET must not be misread as MET (substring trap).
        assert_eq!(
            parse_judge_verdicts("BULLET 1: UNMET - nope", 1)[0].status,
            JudgeStatus::Unmet
        );
        // fail-closed hygiene: out-of-range index, garbage, and no-verdict ⇒ nothing parsed.
        assert!(parse_judge_verdicts("BULLET 9: MET - out of range", 3).is_empty());
        assert!(parse_judge_verdicts("the model rambled with no verdict", 3).is_empty());
        // bare "n. STATUS" form.
        let v2 = parse_judge_verdicts("2. unmet - x", 3);
        assert_eq!(v2.len(), 1);
        assert_eq!(v2[0].index, 1);
        assert_eq!(v2[0].status, JudgeStatus::Unmet);
    }
}
