//! `chump-plan` — standalone binary surface for chump-planner v0.1.
//!
//! The same logic is also reachable as `chump plan` via the main `chump`
//! binary subcommand (see src/main.rs in the workspace root). This standalone
//! binary exists so the crate is independently runnable and so future
//! consumers (Mabel, ChumpMenu, the heartbeat) can shell out without
//! pulling in the entire chump CLI.

use anyhow::{Context, Result};
use chump_planner::{
    build_plan, collect_reconcile, load_gaps_dir,
    output::{json as out_json, table, Format},
    score::TelemetryInputs,
    DependencyGraph, PlanRequest, Weights,
};
use clap::Parser;
use std::path::PathBuf;

#[derive(Parser, Debug)]
#[command(
    name = "chump-plan",
    about = "Rank the gap backlog and recommend the next N to dispatch.",
    version
)]
struct Args {
    /// Path to the gaps directory (default: docs/gaps).
    #[arg(long, default_value = "docs/gaps")]
    gaps: PathBuf,

    /// Plan for N concurrent agents.
    #[arg(long, default_value_t = 5)]
    agents: usize,

    /// Restrict to a single domain (e.g. INFRA, CREDIBLE).
    #[arg(long)]
    pillar: Option<String>,

    /// Skip gaps larger than this effort (xs/s/m/l/xl).
    #[arg(long)]
    max_effort: Option<String>,

    /// Disable the pillar-share cap.
    #[arg(long)]
    no_pillar_cap: bool,

    /// Include gaps with open prerequisites in the rank (default: skip).
    #[arg(long)]
    include_blocked: bool,

    /// Limit output to N items (alias for --agents; preferred for --format json).
    /// When both --top and --agents are provided, --top takes precedence.
    #[arg(long)]
    top: Option<usize>,

    /// Output format. Supports: table, json.
    #[arg(long, default_value = "table")]
    format: String,

    /// Shorthand for `--format json`.
    #[arg(long)]
    json: bool,

    /// Write output to path instead of stdout.
    #[arg(long)]
    output: Option<PathBuf>,

    /// Atomically write JSON output to `.chump-locks/gap-priority.json`.
    #[arg(long)]
    write_lock: bool,

    /// Reconciliation gate threshold. Exits non-zero when
    /// status:open+closed_pr backlog exceeds this count.
    #[arg(long, default_value_t = 10)]
    reconcile_threshold: usize,
}

fn atomic_write_file(target: &std::path::Path, bytes: &[u8]) -> Result<()> {
    if let Some(parent) = target.parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("creating parent dir {}", parent.display()))?;
        }
    }
    let tmp_path = target.with_extension(format!("json.tmp.{}", std::process::id()));
    std::fs::write(&tmp_path, bytes)
        .with_context(|| format!("writing temp file {}", tmp_path.display()))?;
    std::fs::rename(&tmp_path, target).with_context(|| {
        format!(
            "renaming temp file {} -> {}",
            tmp_path.display(),
            target.display()
        )
    })?;
    Ok(())
}

fn main() -> Result<()> {
    let args = Args::parse();
    let format: Format = if args.json || args.write_lock {
        Format::Json
    } else {
        args.format.parse()?
    };

    let gaps = load_gaps_dir(&args.gaps)
        .with_context(|| format!("loading gaps from {}", args.gaps.display()))?;

    let graph = DependencyGraph::build(&gaps);

    if let Err(cycle) = graph.topo_order() {
        // Cycle is informational at v0.1 — surface to stderr, do not crash.
        eprintln!(
            "warning: dependency cycle detected ({} members, identity {}): {:?}",
            cycle.gaps.len(),
            &cycle.identity()[..16],
            cycle.gaps.iter().map(|g| g.0.as_str()).collect::<Vec<_>>(),
        );
    }

    let pillar_filter = match args.pillar.as_deref() {
        Some(s) => Some(
            <chump_planner::Domain as std::str::FromStr>::from_str(s)
                .with_context(|| format!("invalid --pillar {s}"))?,
        ),
        None => None,
    };
    let max_effort = match args.max_effort.as_deref() {
        Some(s) => Some(
            <chump_planner::Effort as std::str::FromStr>::from_str(s)
                .with_context(|| format!("invalid --max-effort {s}"))?,
        ),
        None => None,
    };

    // --top N is the preferred flag for JSON consumers; --agents is kept for
    // the interactive table (where "agents" has semantic meaning).
    let n_results = args.top.unwrap_or(args.agents);
    let req = PlanRequest {
        agents: n_results,
        pillar_filter,
        max_effort,
        respect_pillar_cap: !args.no_pillar_cap,
        include_blocked: args.include_blocked,
    };

    let weights = Weights::default();
    let telemetry = TelemetryInputs::default();
    let today = chrono::Utc::now().date_naive();

    let plan = build_plan(&gaps, &graph, &req, &telemetry, today, &weights);
    let reconcile = collect_reconcile(&gaps);

    let target_file = if let Some(out) = args.output.clone() {
        Some(out)
    } else if args.write_lock {
        Some(PathBuf::from(".chump-locks/gap-priority.json"))
    } else {
        None
    };

    match format {
        Format::Table => {
            let out = table::render(&plan, &reconcile);
            if let Some(target) = target_file {
                atomic_write_file(&target, out.as_bytes())?;
            } else {
                print!("{out}");
            }
        }
        Format::Json => {
            // INFRA-1257 / INFRA-8143: stable JSON v0.2 for the fleet picker.
            let mut buf = Vec::new();
            out_json::render_json(&plan, &weights, &mut buf).context("rendering --format json")?;
            if let Some(target) = target_file {
                atomic_write_file(&target, &buf)?;
            } else {
                use std::io::Write;
                let stdout = std::io::stdout();
                let mut handle = stdout.lock();
                handle.write_all(&buf).context("writing json to stdout")?;
            }
        }
    }

    if reconcile.breaches(args.reconcile_threshold) {
        eprintln!(
            "error: reconciliation backlog {} exceeds threshold {} — run scripts/coord/gap-doctor-reconcile.py",
            reconcile.count(),
            args.reconcile_threshold
        );
        std::process::exit(2);
    }

    Ok(())
}
