//! `POST /api/gap` — authenticated canonical gap-write (INFRA-3689).
//!
//! Second bat-phone surface alongside `POST /api/mission` (EFFECTIVE-513):
//! where `/api/mission` is decompose-oriented intake, `/api/gap` is the raw
//! `chump gap reserve|set|ship` primitive, exposed over HTTP so a
//! non-canonical/stale client (the operator's Mac) can mutate canonical gap
//! state WITHOUT holding a writable local canonical replica. The CLI-side
//! caller lives in the root `chump` binary's gap-mutation path
//! (`src/gap_route.rs`): when `CHUMP_GAP_SERVER` is set and the local
//! checkout is verifiably behind `origin/main`, the CLI routes the mutation
//! here instead of writing `state.db` directly.
//!
//! ## Security
//!
//! Same fail-closed bearer auth as `/api/mission` — the route handler in
//! `routes.rs` reuses `mission::configured_token()` /
//! `mission::constant_time_eq()` verbatim; there is no separate auth path to
//! audit here.
//!
//! ## Ops
//!
//! - `reserve` — `chump gap reserve --domain D --title T [--priority P] [--effort E]`,
//!   then (INFRA-3686 fix) a follow-up `chump gap set <id> --outcome O
//!   --acceptance-criteria ... --priority ...` when any of those fields were
//!   supplied, so a P0/P1 mission with an outcome doesn't 500 on the
//!   MISSION-045 close gate later — the CREATE path now forwards
//!   `req.outcome` all the way through instead of silently dropping it.
//! - `set` — `chump gap set <gap_id> [--description ...] [--priority ...]
//!   [--outcome ...] [--acceptance-criteria ...] [--status ...]`. Requires
//!   `gap_id`.
//! - `ship` — `chump gap ship <gap_id>`. Requires `gap_id`.

use std::path::Path;
use std::process::Command;

use serde::{Deserialize, Serialize};

use crate::mission::{
    is_gap_id, parse_gap_id, resolve_chump_bin, sanitize_effort, sanitize_priority,
};

/// The three ops `POST /api/gap` accepts. Anything else is a 400 at the
/// route handler, before this module ever runs.
pub const ALLOWED_OPS: &[&str] = &["reserve", "set", "ship"];

pub fn is_valid_op(op: &str) -> bool {
    ALLOWED_OPS.contains(&op)
}

/// Inbound gap-mutation payload for `POST /api/gap`.
#[derive(Debug, Default, Deserialize)]
pub struct GapWriteRequest {
    pub op: String,
    #[serde(default)]
    pub domain: Option<String>,
    #[serde(default)]
    pub title: Option<String>,
    #[serde(default)]
    pub gap_id: Option<String>,
    #[serde(default)]
    pub priority: Option<String>,
    #[serde(default)]
    pub outcome: Option<String>,
    #[serde(default)]
    pub effort: Option<String>,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub acceptance_criteria: Option<Vec<String>>,
    #[serde(default)]
    pub status: Option<String>,
    #[serde(default)]
    pub depends_on: Option<String>,
    #[serde(default)]
    pub notes: Option<String>,
    #[serde(default)]
    pub add_note: Option<String>,
    #[serde(default)]
    pub source_doc: Option<String>,
    #[serde(default)]
    pub opened_date: Option<String>,
    #[serde(default)]
    pub closed_date: Option<String>,
    #[serde(default)]
    pub closed_pr: Option<i64>,
    #[serde(default)]
    pub skills_required: Option<String>,
    #[serde(default)]
    pub preferred_backend: Option<String>,
    #[serde(default)]
    pub preferred_machine: Option<String>,
    #[serde(default)]
    pub estimated_minutes: Option<String>,
    #[serde(default)]
    pub required_model: Option<String>,
    /// RESILIENT-1030: `--evidence` text for the CREDIBLE-107 P0/P1
    /// RESILIENT/MISSION/CREDIBLE gate in `chump gap reserve`. Forwarded
    /// verbatim when non-empty; see `execute_gap_write`'s `reserve` arm for
    /// the exemption behavior when this is omitted.
    #[serde(default)]
    pub evidence: Option<String>,
    #[serde(default)]
    pub artifact_type: Option<String>,
    #[serde(default)]
    pub external_repo: Option<String>,
    #[serde(default)]
    pub force: Option<bool>,
    #[serde(default)]
    pub skip_obs_acs: Option<bool>,
    #[serde(default)]
    pub session: Option<String>,
    /// PRODUCT-323: every wire field not modelled above, kept only so an empty
    /// `op=set` can report which fields the caller actually sent.
    #[serde(flatten)]
    pub unrecognised: std::collections::BTreeMap<String, serde_json::Value>,
}

/// A caller error (bad/empty request) — surfaced as HTTP 400, not 500.
#[derive(Debug)]
pub struct InvalidRequest(pub String);

impl std::fmt::Display for InvalidRequest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for InvalidRequest {}

/// Message for an `op=set` that changed nothing: names the fields received so
/// the caller can see which one the server did not recognise.
fn empty_set_message(req: &GapWriteRequest) -> String {
    let mut received: Vec<&str> = req.unrecognised.keys().map(String::as_str).collect();
    received.insert(0, "op");
    if req.gap_id.is_some() {
        received.insert(1, "gap_id");
    }
    format!(
        "op=set requires at least one recognised field to update; received fields: [{}]; \
         unrecognised: [{}]",
        received.join(", "),
        req.unrecognised
            .keys()
            .map(String::as_str)
            .collect::<Vec<_>>()
            .join(", ")
    )
}

/// Result of a successful gap mutation, serialized back to the caller.
#[derive(Debug, Serialize)]
pub struct GapWriteOutcome {
    pub gap_id: String,
    pub op: String,
    pub status: String,
    pub detail: String,
}

fn run_chump(chump: &Path, repo_root: &Path, args: &[&str]) -> anyhow::Result<String> {
    let out = Command::new(chump)
        .current_dir(repo_root)
        .args(args)
        .output()
        .map_err(|e| anyhow::anyhow!("failed to spawn `chump {}`: {e}", args.join(" ")))?;
    if !out.status.success() {
        anyhow::bail!(
            "`chump {}` failed: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        );
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

/// RESILIENT-1030 / CREDIBLE-107: `chump gap reserve` refuses P0/P1
/// RESILIENT/MISSION/CREDIBLE gaps without `--evidence`. The bat-phone
/// bearer token already gates this whole route, so a caller who cleared
/// auth is treated the same as an operator dispatching from the CLI:
/// forward real evidence when given, otherwise pass
/// `--no-evidence-required` so an authed P0/P1 dispatch never 500s on the
/// evidence gate. Pure + unit-testable (no shell-out).
fn evidence_gate_args(evidence: Option<&str>) -> Vec<String> {
    match evidence.map(str::trim) {
        Some(ev) if !ev.is_empty() => vec!["--evidence".into(), ev.to_string()],
        _ => vec!["--no-evidence-required".into()],
    }
}

/// Translate the full `chump gap set` mutation surface into CLI flags. Keep
/// this alongside the wire schema so a canonical client cannot report success
/// while silently dropping fields it would have applied locally.
fn append_string_arg(args: &mut Vec<String>, flag: &str, value: &Option<String>) -> bool {
    if let Some(value) = value {
        args.push(flag.into());
        args.push(value.clone());
        true
    } else {
        false
    }
}

fn append_set_args(args: &mut Vec<String>, req: &GapWriteRequest) -> bool {
    let mut touched = append_string_arg(args, "--title", &req.title);
    touched |= append_string_arg(args, "--description", &req.description);
    if let Some(v) = &req.priority {
        args.push("--priority".into());
        args.push(sanitize_priority(Some(v)));
        touched = true;
    }
    if let Some(v) = &req.effort {
        args.push("--effort".into());
        args.push(sanitize_effort(Some(v)));
        touched = true;
    }
    touched |= append_string_arg(args, "--status", &req.status);
    touched |= append_string_arg(args, "--outcome", &req.outcome);
    if let Some(ac_list) = &req.acceptance_criteria {
        for ac in ac_list {
            args.push("--acceptance-criteria".into());
            args.push(ac.clone());
            touched = true;
        }
    }
    touched |= append_string_arg(args, "--depends-on", &req.depends_on);
    touched |= append_string_arg(args, "--notes", &req.notes);
    touched |= append_string_arg(args, "--add-note", &req.add_note);
    touched |= append_string_arg(args, "--source-doc", &req.source_doc);
    touched |= append_string_arg(args, "--opened-date", &req.opened_date);
    touched |= append_string_arg(args, "--closed-date", &req.closed_date);
    if let Some(v) = req.closed_pr {
        args.push("--closed-pr".into());
        args.push(v.to_string());
        touched = true;
    }
    touched |= append_string_arg(args, "--skills-required", &req.skills_required);
    touched |= append_string_arg(args, "--preferred-backend", &req.preferred_backend);
    touched |= append_string_arg(args, "--preferred-machine", &req.preferred_machine);
    touched |= append_string_arg(args, "--estimated-minutes", &req.estimated_minutes);
    touched |= append_string_arg(args, "--required-model", &req.required_model);
    touched |= append_string_arg(args, "--evidence", &req.evidence);
    touched |= append_string_arg(args, "--artifact-type", &req.artifact_type);
    touched
}

/// Execute a `reserve|set|ship` gap mutation canonically (blocking; call
/// from `spawn_blocking`), reusing the exact `Command::new(chump)
/// .current_dir(repo_root)...` pattern `mission::create_mission_gap` uses
/// for `POST /api/mission`.
pub fn execute_gap_write(
    repo_root: &Path,
    req: GapWriteRequest,
) -> anyhow::Result<GapWriteOutcome> {
    let op = req.op.trim().to_lowercase();
    if !is_valid_op(&op) {
        anyhow::bail!("unsupported op {:?} (allowed: {:?})", req.op, ALLOWED_OPS);
    }
    let chump = resolve_chump_bin(repo_root);

    match op.as_str() {
        "reserve" => {
            let domain = req
                .domain
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .ok_or_else(|| anyhow::anyhow!("op=reserve requires non-empty `domain`"))?;
            let title = req
                .title
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .ok_or_else(|| anyhow::anyhow!("op=reserve requires non-empty `title`"))?;
            let priority = sanitize_priority(req.priority.as_deref());
            let effort = sanitize_effort(req.effort.as_deref());
            let domain_up = crate::mission::sanitize_domain(domain);

            let mut reserve_args: Vec<String> = vec![
                "gap".into(),
                "reserve".into(),
                "--domain".into(),
                domain_up,
                "--title".into(),
                title.to_string(),
                "--priority".into(),
                priority,
                "--effort".into(),
                effort,
            ];
            reserve_args.extend(evidence_gate_args(req.evidence.as_deref()));
            if req.force == Some(true) {
                reserve_args.push("--force".into());
            }
            if req.skip_obs_acs == Some(true) {
                reserve_args.push("--skip-obs-acs".into());
            }
            if let Some(ref ac_list) = req.acceptance_criteria {
                let ac: Vec<&str> = ac_list
                    .iter()
                    .map(String::as_str)
                    .filter(|item| !item.trim().is_empty())
                    .collect();
                if !ac.is_empty() {
                    reserve_args.push("--acceptance-criteria".into());
                    reserve_args.push(ac.join("|"));
                }
            }
            if let Some(ref external_repo) = req.external_repo {
                reserve_args.push("--external-repo".into());
                reserve_args.push(external_repo.clone());
            }
            let reserve_args_ref: Vec<&str> = reserve_args.iter().map(String::as_str).collect();

            let stdout = run_chump(&chump, repo_root, &reserve_args_ref)?;
            let gap_id = parse_gap_id(&stdout).ok_or_else(|| {
                anyhow::anyhow!(
                    "could not parse gap id from reserve output: {}",
                    stdout.trim()
                )
            })?;
            if !is_gap_id(&gap_id) {
                anyhow::bail!("reserve produced a malformed gap id: {gap_id:?}");
            }

            // INFRA-3686 fix: forward outcome/priority/AC/description via a
            // follow-up `gap set` so a P0/P1 mission with an outcome doesn't
            // silently drop it and 500 later on the MISSION-045 close gate.
            let mut set_args: Vec<String> = vec!["gap".into(), "set".into(), gap_id.clone()];
            let has_set_fields = append_set_args(&mut set_args, &req);
            if has_set_fields {
                let args_ref: Vec<&str> = set_args.iter().map(String::as_str).collect();
                run_chump(&chump, repo_root, &args_ref)?;
            }

            Ok(GapWriteOutcome {
                gap_id,
                op: "reserve".into(),
                status: "reserved".into(),
                detail: if has_set_fields {
                    "gap reserved; outcome/description/AC applied via follow-up gap set".into()
                } else {
                    "gap reserved".into()
                },
            })
        }
        "set" => {
            let gap_id = req
                .gap_id
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .ok_or_else(|| anyhow::anyhow!("op=set requires non-empty `gap_id`"))?;
            if !is_gap_id(gap_id) {
                anyhow::bail!("op=set: {gap_id:?} does not look like a gap id");
            }
            let mut set_args: Vec<String> = vec!["gap".into(), "set".into(), gap_id.to_string()];
            let touched = append_set_args(&mut set_args, &req);
            if !touched {
                return Err(InvalidRequest(empty_set_message(&req)).into());
            }
            let args_ref: Vec<&str> = set_args.iter().map(String::as_str).collect();
            run_chump(&chump, repo_root, &args_ref)?;
            Ok(GapWriteOutcome {
                gap_id: gap_id.to_string(),
                op: "set".into(),
                status: "updated".into(),
                detail: "gap fields updated".into(),
            })
        }
        "ship" => {
            let gap_id = req
                .gap_id
                .as_deref()
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .ok_or_else(|| anyhow::anyhow!("op=ship requires non-empty `gap_id`"))?;
            if !is_gap_id(gap_id) {
                anyhow::bail!("op=ship: {gap_id:?} does not look like a gap id");
            }
            let mut ship_args = vec!["gap".to_string(), "ship".to_string(), gap_id.to_string()];
            if let Some(closed_pr) = req.closed_pr {
                ship_args.push("--closed-pr".into());
                ship_args.push(closed_pr.to_string());
            }
            if let Some(ref session) = req.session {
                ship_args.push("--session".into());
                ship_args.push(session.clone());
            }
            let ship_args_ref: Vec<&str> = ship_args.iter().map(String::as_str).collect();
            run_chump(&chump, repo_root, &ship_args_ref)?;
            Ok(GapWriteOutcome {
                gap_id: gap_id.to_string(),
                op: "ship".into(),
                status: "done".into(),
                detail: "gap shipped".into(),
            })
        }
        other => anyhow::bail!("unsupported op {other:?}"),
    }
}

/// Canonical priority rank used to order `/api/gaps` P0-first (INFRA-8179).
///
/// Maps both `P0..P4` and `critical/high/medium/low` onto `0..=4` so mixed
/// priority vocabularies sort deterministically with P0 / critical at the top.
pub fn priority_rank(p: &str) -> u8 {
    match p.trim().to_ascii_lowercase().as_str() {
        "p0" | "critical" => 0,
        "p1" | "high" => 1,
        "p2" | "medium" => 2,
        "p3" | "low" => 3,
        "p4" => 4,
        _ => 99,
    }
}

fn priority_matches(gap_priority: &str, filter_priority: &str) -> bool {
    let filter_trimmed = filter_priority.trim();
    if filter_trimmed.is_empty() || filter_trimmed.eq_ignore_ascii_case("all") {
        return true;
    }
    let gap_p = gap_priority.trim();
    let gap_rank = priority_rank(gap_p);
    filter_trimmed
        .split(',')
        .map(str::trim)
        .filter(|tok| !tok.is_empty())
        .any(|tok| {
            gap_p.eq_ignore_ascii_case(tok) || (gap_rank != 99 && gap_rank == priority_rank(tok))
        })
}

fn status_matches(gap_status: &str, filter_status: &str) -> bool {
    let filter_trimmed = filter_status.trim();
    if filter_trimmed.is_empty() || filter_trimmed.eq_ignore_ascii_case("all") {
        return true;
    }
    let gap_s = gap_status.trim();
    filter_trimmed
        .split(',')
        .map(str::trim)
        .filter(|tok| !tok.is_empty())
        .any(|tok| gap_s.eq_ignore_ascii_case(tok))
}

fn domain_matches(gap_domain: &str, filter_domain: &str) -> bool {
    let filter_trimmed = filter_domain.trim();
    if filter_trimmed.is_empty() || filter_trimmed.eq_ignore_ascii_case("all") {
        return true;
    }
    let gap_d = gap_domain.trim();
    filter_trimmed
        .split(',')
        .map(str::trim)
        .filter(|tok| !tok.is_empty())
        .any(|tok| gap_d.eq_ignore_ascii_case(tok))
}

/// Filter and stably sort a gap-list JSON value by priority (`priority_rank`:
/// `P0 < P1 < P2 < P3`, `critical < high < medium < low`), honoring optional
/// `status`, `priority`, and `domain` filters (INFRA-8179).
pub fn sort_and_filter_gaps_value(
    value: serde_json::Value,
    status: Option<&str>,
    priority: Option<&str>,
    domain: Option<&str>,
) -> serde_json::Value {
    let filter_and_sort = |items: Vec<serde_json::Value>| -> Vec<serde_json::Value> {
        let mut out: Vec<serde_json::Value> = items
            .into_iter()
            .filter(|item| {
                if let Some(s) = status {
                    let gs = item.get("status").and_then(|v| v.as_str()).unwrap_or("");
                    if !status_matches(gs, s) {
                        return false;
                    }
                }
                if let Some(p) = priority {
                    let gp = item.get("priority").and_then(|v| v.as_str()).unwrap_or("");
                    if !priority_matches(gp, p) {
                        return false;
                    }
                }
                if let Some(d) = domain {
                    let gd = item.get("domain").and_then(|v| v.as_str()).unwrap_or("");
                    if !domain_matches(gd, d) {
                        return false;
                    }
                }
                true
            })
            .collect();
        out.sort_by(|a, b| {
            let pa = a
                .get("priority")
                .and_then(|v| v.as_str())
                .map(priority_rank)
                .unwrap_or(99);
            let pb = b
                .get("priority")
                .and_then(|v| v.as_str())
                .map(priority_rank)
                .unwrap_or(99);
            pa.cmp(&pb)
        });
        out
    };

    match value {
        serde_json::Value::Array(items) => serde_json::Value::Array(filter_and_sort(items)),
        serde_json::Value::Object(mut map) => {
            if let Some(serde_json::Value::Array(items)) = map.remove("gaps") {
                let sorted = filter_and_sort(items);
                if map.contains_key("total") {
                    map.insert(
                        "total".to_string(),
                        serde_json::Value::from(sorted.len() as u64),
                    );
                }
                map.insert("gaps".to_string(), serde_json::Value::Array(sorted));
            }
            serde_json::Value::Object(map)
        }
        other => other,
    }
}

/// `GET /api/gaps` (RESILIENT-1030 / INFRA-8179): authed read of the gap queue
/// state, sorted by `priority_rank` (`P0 < P1 < P2 < P3`, `critical < high <
/// medium < low`) and filtered by optional `status`, `priority`, and `domain`
/// query parameters. Defaults to `status=open` when `status` is omitted.
pub fn list_gaps_filtered(
    repo_root: &Path,
    status: Option<&str>,
    priority: Option<&str>,
    domain: Option<&str>,
) -> anyhow::Result<serde_json::Value> {
    let chump = resolve_chump_bin(repo_root);
    let effective_status = status
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .unwrap_or("open");

    let mut args: Vec<String> = vec!["gap".into(), "list".into()];
    if !effective_status.contains(',') && !effective_status.eq_ignore_ascii_case("all") {
        args.push("--status".into());
        args.push(effective_status.to_string());
    }
    if let Some(d) = domain
        .map(str::trim)
        .filter(|d| !d.is_empty() && !d.contains(','))
    {
        if !d.eq_ignore_ascii_case("all") {
            args.push("--domain".into());
            args.push(d.to_string());
        }
    }
    args.push("--json".into());

    let args_ref: Vec<&str> = args.iter().map(String::as_str).collect();
    let stdout = run_chump(&chump, repo_root, &args_ref)?;
    let parsed = parse_gap_list_json(&stdout)?;
    Ok(sort_and_filter_gaps_value(
        parsed,
        Some(effective_status),
        priority,
        domain,
    ))
}

/// `GET /api/gaps` (RESILIENT-1030): authed read of the open-gap queue
/// state, sorted P0-first per INFRA-8179.
pub fn list_open_gaps(repo_root: &Path) -> anyhow::Result<serde_json::Value> {
    list_gaps_filtered(repo_root, None, None, None)
}

/// Pure JSON-parse step, split out from `list_open_gaps` so it's
/// unit-testable without shelling out to a real `chump` binary.
fn parse_gap_list_json(stdout: &str) -> anyhow::Result<serde_json::Value> {
    serde_json::from_str(stdout)
        .map_err(|e| anyhow::anyhow!("could not parse `chump gap list --json` output: {e}"))
}

// ── store-over-API canonical SQLite read endpoints (RESILIENT-1700) ──────────

/// Canonical SQLite `gaps` column order for `GET /api/store/gaps` and
/// `GET /api/store/gaps/{id}` (RESILIENT-1700).
pub const CANONICAL_GAP_COLUMNS: &[&str] = &[
    "id",
    "title",
    "description",
    "domain",
    "priority",
    "status",
    "effort",
    "skills_required",
    "acceptance_criteria",
    "depends_on",
    "parent_id",
    "notes",
    "closed_pr",
    "closed_date",
    "created_at",
];

/// Canonical gap row serialized in the exact 15-column declaration order so
/// `GET /api/store/gaps?order=id` is byte-identical to
/// `sqlite3 -json state.db "SELECT id, title, description, domain, priority, status, effort, skills_required, acceptance_criteria, depends_on, parent_id, notes, closed_pr, closed_date, created_at FROM gaps ORDER BY id ASC"`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct CanonicalGapRow {
    pub id: serde_json::Value,
    pub title: serde_json::Value,
    pub description: serde_json::Value,
    pub domain: serde_json::Value,
    pub priority: serde_json::Value,
    pub status: serde_json::Value,
    pub effort: serde_json::Value,
    pub skills_required: serde_json::Value,
    pub acceptance_criteria: serde_json::Value,
    pub depends_on: serde_json::Value,
    pub parent_id: serde_json::Value,
    pub notes: serde_json::Value,
    pub closed_pr: serde_json::Value,
    pub closed_date: serde_json::Value,
    pub created_at: serde_json::Value,
}

fn sqlite_val_to_json(v: rusqlite::types::ValueRef<'_>) -> serde_json::Value {
    match v {
        rusqlite::types::ValueRef::Null => serde_json::Value::Null,
        rusqlite::types::ValueRef::Integer(i) => serde_json::Value::from(i),
        rusqlite::types::ValueRef::Real(f) => serde_json::Number::from_f64(f)
            .map(serde_json::Value::Number)
            .unwrap_or(serde_json::Value::Null),
        rusqlite::types::ValueRef::Text(t) => {
            serde_json::Value::String(String::from_utf8_lossy(t).into_owned())
        }
        rusqlite::types::ValueRef::Blob(b) => {
            serde_json::Value::String(String::from_utf8_lossy(b).into_owned())
        }
    }
}

fn row_to_canonical_gap(r: &rusqlite::Row<'_>) -> rusqlite::Result<CanonicalGapRow> {
    Ok(CanonicalGapRow {
        id: sqlite_val_to_json(r.get_ref(0)?),
        title: sqlite_val_to_json(r.get_ref(1)?),
        description: sqlite_val_to_json(r.get_ref(2)?),
        domain: sqlite_val_to_json(r.get_ref(3)?),
        priority: sqlite_val_to_json(r.get_ref(4)?),
        status: sqlite_val_to_json(r.get_ref(5)?),
        effort: sqlite_val_to_json(r.get_ref(6)?),
        skills_required: sqlite_val_to_json(r.get_ref(7)?),
        acceptance_criteria: sqlite_val_to_json(r.get_ref(8)?),
        depends_on: sqlite_val_to_json(r.get_ref(9)?),
        parent_id: sqlite_val_to_json(r.get_ref(10)?),
        notes: sqlite_val_to_json(r.get_ref(11)?),
        closed_pr: sqlite_val_to_json(r.get_ref(12)?),
        closed_date: sqlite_val_to_json(r.get_ref(13)?),
        created_at: sqlite_val_to_json(r.get_ref(14)?),
    })
}

/// Resolve the SQLite `state.db` path for store-over-API reads:
/// 1. `CHUMP_STATE_DB` when set and non-empty (via `chump_store_path`),
/// 2. `<repo_root>/.chump/state.db` or `<repo_root>/state.db` when present on disk,
/// 3. `chump_store_path::state_db_path(repo_root)`.
pub fn resolve_state_db_path(repo_root: &Path) -> std::path::PathBuf {
    if std::env::var(chump_store_path::STATE_DB_ENV)
        .ok()
        .map(|s| !s.trim().is_empty())
        .unwrap_or(false)
    {
        return chump_store_path::state_db_path(repo_root);
    }
    let dot_chump = repo_root.join(".chump").join("state.db");
    if dot_chump.is_file() {
        return dot_chump;
    }
    let direct = repo_root.join("state.db");
    if direct.is_file() {
        return direct;
    }
    chump_store_path::state_db_path(repo_root)
}

fn existing_gap_columns(
    conn: &rusqlite::Connection,
) -> anyhow::Result<std::collections::BTreeSet<String>> {
    let mut stmt = conn.prepare("PRAGMA table_info(gaps)")?;
    let cols = stmt
        .query_map([], |r| r.get::<_, String>(1))?
        .collect::<std::result::Result<std::collections::BTreeSet<String>, _>>()?;
    Ok(cols)
}

fn canonical_select_list(existing: &std::collections::BTreeSet<String>) -> String {
    CANONICAL_GAP_COLUMNS
        .iter()
        .map(|col| {
            if existing.contains(*col) {
                (*col).to_string()
            } else {
                format!("NULL AS {col}")
            }
        })
        .collect::<Vec<_>>()
        .join(", ")
}

/// Query canonical `gaps` rows from `state.db` (RESILIENT-1700), supporting
/// optional `?status=`, `?priority=`, `?domain=`, `?limit=`, and
/// `?order=id|priority` parameters.
pub fn query_store_gaps(
    repo_root: &Path,
    status: Option<&str>,
    priority: Option<&str>,
    domain: Option<&str>,
    limit: Option<usize>,
    order: Option<&str>,
) -> anyhow::Result<Vec<CanonicalGapRow>> {
    let db_path = resolve_state_db_path(repo_root);
    if !db_path.is_file() {
        return Ok(Vec::new());
    }
    let conn = rusqlite::Connection::open_with_flags(
        &db_path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )?;
    let existing = existing_gap_columns(&conn)?;
    if existing.is_empty() {
        return Ok(Vec::new());
    }
    let select_cols = canonical_select_list(&existing);
    let sql = format!("SELECT {select_cols} FROM gaps ORDER BY id ASC");
    let mut stmt = conn.prepare(&sql)?;
    let iter = stmt.query_map([], row_to_canonical_gap)?;

    let mut rows: Vec<CanonicalGapRow> = Vec::new();
    for item in iter {
        let row = item?;
        if let Some(s) = status {
            let gs = row.status.as_str().unwrap_or("");
            if !status_matches(gs, s) {
                continue;
            }
        }
        if let Some(p) = priority {
            let gp = row.priority.as_str().unwrap_or("");
            if !priority_matches(gp, p) {
                continue;
            }
        }
        if let Some(d) = domain {
            let gd = row.domain.as_str().unwrap_or("");
            if !domain_matches(gd, d) {
                continue;
            }
        }
        rows.push(row);
    }

    if order
        .map(|o| o.trim().eq_ignore_ascii_case("priority"))
        .unwrap_or(false)
    {
        rows.sort_by(|a, b| {
            let pa = a.priority.as_str().map(priority_rank).unwrap_or(99);
            let pb = b.priority.as_str().map(priority_rank).unwrap_or(99);
            pa.cmp(&pb)
                .then_with(|| a.id.as_str().unwrap_or("").cmp(b.id.as_str().unwrap_or("")))
        });
    }

    if let Some(lim) = limit {
        rows.truncate(lim);
    }

    Ok(rows)
}

/// Format a slice of [`CanonicalGapRow`] into the exact `[{row},\n{row}]\n`
/// representation produced by `sqlite3 -json` (RESILIENT-1700).
pub fn format_sqlite_json_array(rows: &[CanonicalGapRow]) -> String {
    if rows.is_empty() {
        return "[]\n".to_string();
    }
    let items: Vec<String> = rows
        .iter()
        .filter_map(|r| serde_json::to_string(r).ok())
        .collect();
    format!("[{}]\n", items.join(",\n"))
}

/// Query a single canonical gap row by `id` from `state.db` (RESILIENT-1700).
pub fn query_store_gap_by_id(
    repo_root: &Path,
    gap_id: &str,
) -> anyhow::Result<Option<CanonicalGapRow>> {
    let db_path = resolve_state_db_path(repo_root);
    if !db_path.is_file() {
        return Ok(None);
    }
    let conn = rusqlite::Connection::open_with_flags(
        &db_path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )?;
    let existing = existing_gap_columns(&conn)?;
    if existing.is_empty() {
        return Ok(None);
    }
    let select_cols = canonical_select_list(&existing);
    let sql = format!("SELECT {select_cols} FROM gaps WHERE id = ?1 LIMIT 1");
    let mut stmt = conn.prepare(&sql)?;
    let mut rows = stmt.query_map(rusqlite::params![gap_id], row_to_canonical_gap)?;
    match rows.next() {
        Some(Ok(row)) => Ok(Some(row)),
        Some(Err(e)) => Err(e.into()),
        None => Ok(None),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_set_message_names_received_fields() {
        let req: GapWriteRequest =
            serde_json::from_str(r#"{"op":"set","gap_id":"INFRA-1","note":"x","source":"holler"}"#)
                .unwrap();
        let mut args = vec![];
        assert!(!append_set_args(&mut args, &req));
        let msg = empty_set_message(&req);
        assert!(
            msg.contains("received fields: [op, gap_id, note, source]"),
            "{msg}"
        );
        assert!(msg.contains("unrecognised: [note, source]"), "{msg}");
    }

    #[test]
    fn is_valid_op_allows_only_the_three_ops() {
        assert!(is_valid_op("reserve"));
        assert!(is_valid_op("set"));
        assert!(is_valid_op("ship"));
        assert!(!is_valid_op("delete"));
        assert!(!is_valid_op(""));
        assert!(!is_valid_op("RESERVE")); // case-sensitive at this layer; execute_gap_write lowercases first
    }

    #[test]
    fn execute_gap_write_rejects_bad_op_before_shelling_out() {
        let req = GapWriteRequest {
            op: "delete".into(),
            ..Default::default()
        };
        let err = execute_gap_write(Path::new("/nonexistent"), req).unwrap_err();
        assert!(err.to_string().contains("unsupported op"));
    }

    #[test]
    fn execute_gap_write_reserve_requires_domain_and_title() {
        let req = GapWriteRequest {
            op: "reserve".into(),
            title: Some("t".into()),
            ..Default::default()
        };
        let err = execute_gap_write(Path::new("/nonexistent"), req).unwrap_err();
        assert!(err.to_string().contains("domain"));
    }

    #[test]
    fn execute_gap_write_set_requires_gap_id_and_a_field() {
        let req = GapWriteRequest {
            op: "set".into(),
            ..Default::default()
        };
        let err = execute_gap_write(Path::new("/nonexistent"), req).unwrap_err();
        assert!(err.to_string().contains("gap_id"));
    }

    #[test]
    fn execute_gap_write_ship_requires_gap_id() {
        let req = GapWriteRequest {
            op: "ship".into(),
            ..Default::default()
        };
        let err = execute_gap_write(Path::new("/nonexistent"), req).unwrap_err();
        assert!(err.to_string().contains("gap_id"));
    }

    #[test]
    fn append_set_args_preserves_nontrivial_mutation_fields() {
        let req = GapWriteRequest {
            title: Some("new title".into()),
            depends_on: Some("INFRA-1,INFRA-2".into()),
            add_note: Some("operator note".into()),
            closed_pr: Some(42),
            artifact_type: Some("design".into()),
            ..Default::default()
        };
        let mut args = vec!["gap".into(), "set".into(), "INFRA-9".into()];

        assert!(append_set_args(&mut args, &req));
        assert_eq!(
            args,
            vec![
                "gap",
                "set",
                "INFRA-9",
                "--title",
                "new title",
                "--depends-on",
                "INFRA-1,INFRA-2",
                "--add-note",
                "operator note",
                "--closed-pr",
                "42",
                "--artifact-type",
                "design",
            ]
        );
    }

    // RESILIENT-1030: the evidence gate must forward real evidence when
    // given, and otherwise exempt the (already bearer-authed) dispatch via
    // `--no-evidence-required` instead of letting P0/P1 RESILIENT/MISSION/
    // CREDIBLE reserves 500 against the CREDIBLE-107 CLI gate.
    #[test]
    fn evidence_gate_forwards_real_evidence_when_present() {
        let args = evidence_gate_args(Some("COMMAND/OUTPUT/THEORY/ALT"));
        assert_eq!(args, vec!["--evidence", "COMMAND/OUTPUT/THEORY/ALT"]);
    }

    #[test]
    fn evidence_gate_exempts_authed_dispatch_when_absent() {
        assert_eq!(evidence_gate_args(None), vec!["--no-evidence-required"]);
        assert_eq!(evidence_gate_args(Some("")), vec!["--no-evidence-required"]);
        assert_eq!(
            evidence_gate_args(Some("   ")),
            vec!["--no-evidence-required"]
        );
    }

    #[test]
    fn parse_gap_list_json_accepts_a_valid_array() {
        let parsed = parse_gap_list_json(r#"[{"id":"RESILIENT-1","status":"open"}]"#).unwrap();
        assert_eq!(parsed[0]["id"], "RESILIENT-1");
    }

    #[test]
    fn parse_gap_list_json_rejects_garbage() {
        let err = parse_gap_list_json("not json").unwrap_err();
        assert!(err.to_string().contains("could not parse"));
    }

    #[test]
    fn priority_rank_orders_p0_through_p3_and_critical_through_low() {
        assert_eq!(priority_rank("P0"), 0);
        assert_eq!(priority_rank("critical"), 0);
        assert_eq!(priority_rank("P1"), 1);
        assert_eq!(priority_rank("high"), 1);
        assert_eq!(priority_rank("P2"), 2);
        assert_eq!(priority_rank("medium"), 2);
        assert_eq!(priority_rank("P3"), 3);
        assert_eq!(priority_rank("low"), 3);
        assert!(priority_rank("P0") < priority_rank("P1"));
        assert!(priority_rank("P1") < priority_rank("P2"));
        assert!(priority_rank("P2") < priority_rank("P3"));
        assert!(priority_rank("critical") < priority_rank("high"));
        assert!(priority_rank("high") < priority_rank("medium"));
        assert!(priority_rank("medium") < priority_rank("low"));
    }

    #[test]
    fn sort_and_filter_gaps_value_sorts_p0_first_and_honors_filters() {
        let raw = serde_json::json!([
            {"id": "INFRA-100", "priority": "P2", "status": "open", "domain": "INFRA"},
            {"id": "INFRA-200", "priority": "P0", "status": "open", "domain": "INFRA"},
            {"id": "INFRA-300", "priority": "high", "status": "open", "domain": "INFRA"},
            {"id": "INFRA-400", "priority": "critical", "status": "done", "domain": "INFRA"}
        ]);

        // Default open filter: drops INFRA-400 (done) and orders P0 < high(P1) < P2.
        let sorted = sort_and_filter_gaps_value(raw.clone(), Some("open"), None, None);
        let arr = sorted.as_array().unwrap();
        let ids: Vec<&str> = arr.iter().map(|g| g["id"].as_str().unwrap()).collect();
        assert_eq!(ids, vec!["INFRA-200", "INFRA-300", "INFRA-100"]);

        // Priority filter ?priority=P0 returns only P0 / critical open gaps.
        let p0_only = sort_and_filter_gaps_value(raw.clone(), Some("open"), Some("P0"), None);
        let p0_arr = p0_only.as_array().unwrap();
        assert_eq!(p0_arr.len(), 1);
        assert_eq!(p0_arr[0]["id"], "INFRA-200");

        // Status filter ?status=done&priority=P0 matches critical (rank 0) done gap.
        let done_p0 = sort_and_filter_gaps_value(raw, Some("done"), Some("P0"), None);
        let done_arr = done_p0.as_array().unwrap();
        assert_eq!(done_arr.len(), 1);
        assert_eq!(done_arr[0]["id"], "INFRA-400");
    }

    #[test]
    fn query_store_gaps_and_by_id_match_canonical_sqlite_rows_resilient_1700() {
        let tmp = tempfile::tempdir().expect("tempdir");
        let chump_dir = tmp.path().join(".chump");
        std::fs::create_dir_all(&chump_dir).expect("create .chump");
        let db_path = chump_dir.join("state.db");
        let conn = rusqlite::Connection::open(&db_path).expect("open db");
        conn.execute_batch(
            "CREATE TABLE gaps (
                id TEXT PRIMARY KEY,
                title TEXT,
                description TEXT,
                domain TEXT,
                priority TEXT,
                status TEXT,
                effort TEXT,
                skills_required TEXT,
                acceptance_criteria TEXT,
                depends_on TEXT,
                parent_id TEXT,
                notes TEXT,
                closed_pr INTEGER,
                closed_date TEXT,
                created_at INTEGER
            );
            INSERT INTO gaps VALUES
                ('INFRA-200', 'Beta gap', 'beta desc', 'INFRA', 'P0', 'open', 's', 'rust', '[\"ac1\"]', '[]', NULL, 'note2', NULL, '', 1778700200),
                ('INFRA-100', 'Alpha gap', 'alpha desc', 'INFRA', 'P2', 'open', 'm', '', '[\"ac1\",\"ac2\"]', '[\"INFRA-200\"]', 'RESILIENT-1691', 'note1', NULL, '', 1778700100),
                ('RESILIENT-050', 'Gamma gap', 'gamma desc', 'RESILIENT', 'P1', 'done', 'xs', '', '[]', '[]', NULL, '', 42, '2026-10-25', 1778700050);",
        )
        .expect("seed gaps");
        drop(conn);

        // 1. order=id returns deterministic ORDER BY id ASC matching canonical SQLite schema.
        let rows = query_store_gaps(tmp.path(), None, None, None, None, Some("id"))
            .expect("query_store_gaps");
        assert_eq!(rows.len(), 3);
        assert_eq!(rows[0].id, serde_json::json!("INFRA-100"));
        assert_eq!(rows[1].id, serde_json::json!("INFRA-200"));
        assert_eq!(rows[2].id, serde_json::json!("RESILIENT-050"));
        assert_eq!(rows[0].parent_id, serde_json::json!("RESILIENT-1691"));
        assert_eq!(rows[1].parent_id, serde_json::Value::Null);
        assert_eq!(rows[2].closed_pr, serde_json::json!(42));

        // Verify serialized JSON has exact field order and sqlite3 -json row formatting.
        let json_str = format_sqlite_json_array(&rows);
        let expected = concat!(
            "[{\"id\":\"INFRA-100\",\"title\":\"Alpha gap\",\"description\":\"alpha desc\",\"domain\":\"INFRA\",\"priority\":\"P2\",\"status\":\"open\",\"effort\":\"m\",\"skills_required\":\"\",\"acceptance_criteria\":\"[\\\"ac1\\\",\\\"ac2\\\"]\",\"depends_on\":\"[\\\"INFRA-200\\\"]\",\"parent_id\":\"RESILIENT-1691\",\"notes\":\"note1\",\"closed_pr\":null,\"closed_date\":\"\",\"created_at\":1778700100},\n",
            "{\"id\":\"INFRA-200\",\"title\":\"Beta gap\",\"description\":\"beta desc\",\"domain\":\"INFRA\",\"priority\":\"P0\",\"status\":\"open\",\"effort\":\"s\",\"skills_required\":\"rust\",\"acceptance_criteria\":\"[\\\"ac1\\\"]\",\"depends_on\":\"[]\",\"parent_id\":null,\"notes\":\"note2\",\"closed_pr\":null,\"closed_date\":\"\",\"created_at\":1778700200},\n",
            "{\"id\":\"RESILIENT-050\",\"title\":\"Gamma gap\",\"description\":\"gamma desc\",\"domain\":\"RESILIENT\",\"priority\":\"P1\",\"status\":\"done\",\"effort\":\"xs\",\"skills_required\":\"\",\"acceptance_criteria\":\"[]\",\"depends_on\":\"[]\",\"parent_id\":null,\"notes\":\"\",\"closed_pr\":42,\"closed_date\":\"2026-10-25\",\"created_at\":1778700050}]\n"
        );
        assert_eq!(json_str, expected);

        // 2. Filters + order=priority + limit.
        let open_by_prio = query_store_gaps(
            tmp.path(),
            Some("open"),
            None,
            Some("INFRA"),
            Some(1),
            Some("priority"),
        )
        .expect("filtered query");
        assert_eq!(open_by_prio.len(), 1);
        assert_eq!(open_by_prio[0].id, serde_json::json!("INFRA-200"));

        // 3. Single gap lookup by ID.
        let single = query_store_gap_by_id(tmp.path(), "INFRA-100")
            .expect("query by id")
            .expect("gap exists");
        assert_eq!(single, rows[0]);

        let missing = query_store_gap_by_id(tmp.path(), "DOES-NOT-EXIST").expect("query missing");
        assert!(missing.is_none());
    }
}
