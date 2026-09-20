//! chump-coord — CLI for the NATS atomic coordination layer.
//!
//! All commands degrade gracefully when NATS is unreachable (exit 0 with a
//! warning), so shell scripts can use `chump-coord ping` as a guard and fall
//! back to file-based leases when NATS is down.
//!
//! Commands:
//!   ping                       — check NATS reachability (exit 0 = up)
//!   claim <gap-id>             — atomic claim (exit 0 = won, 1 = lost to another session)
//!   release <gap-id>           — release claim
//!   merge-lock <sub> [args …]  — INFRA-7714 (INFRA-2252 slice): local-merge-queue CAS lock
//!                                 (acquire <holder>|release|status)
//!                                 exit 0 = acquired/released, 1 = held by another holder,
//!                                 2 = usage error, 3 = NATS unreachable
//!   status                     — show all active claims + recent events
//!   emit <type> [key=value …]  — publish a structured event
//!   watch                      — stream live events (ctrl-c to stop)
//!   work-board <sub> [args …]  — FLEET-008 shared subtask queue (post|list|claim|complete|fail|show)
//!   help-request <sub> [args …] — FLEET-010 help-seeking protocol (post|list|claim|complete|fail|show)
//!   workers [--json]           — CREDIBLE-257: list registered workers + live state
//!
//! Environment:
//!   CHUMP_NATS_URL             — default nats://127.0.0.1:4222
//!   CHUMP_SESSION_ID           — your session identity (falls back to UUID)
//!   CHUMP_COORD_FILES          — comma-separated file hints for claim command

use anyhow::Result;
use chump_coord::help_request::{BlockerType, HelpRequest, HelpStatus};
use chump_coord::work_board::{Requirement, Subtask, SubtaskStatus, TransitionMiss};
use chump_coord::{CoordClient, CoordEvent};
use std::env;

fn print_transition_miss(verb: &str, id: &str, miss: &TransitionMiss) {
    match miss {
        TransitionMiss::NotFound => {
            eprintln!("[chump-coord] cannot {} {}: not found", verb, id);
        }
        TransitionMiss::StaleRevision => {
            eprintln!(
                "[chump-coord] cannot {} {}: another agent updated it first (stale revision)",
                verb, id
            );
        }
        TransitionMiss::WrongState(s) => {
            eprintln!(
                "[chump-coord] cannot {} {}: subtask is in state {:?}, not the expected state",
                verb, id, s
            );
        }
        TransitionMiss::NotClaimHolder { holder, caller } => {
            eprintln!(
                "[chump-coord] cannot {} {}: claim is held by {} but caller is {}",
                verb, id, holder, caller
            );
        }
    }
}

fn session_id() -> String {
    // Priority mirrors gap-claim.sh: explicit > CLAUDE_SESSION_ID > UUID
    env::var("CHUMP_SESSION_ID")
        .or_else(|_| env::var("CLAUDE_SESSION_ID"))
        .unwrap_or_else(|_| {
            // Stable per-worktree ID from cache file if present
            let wt_cache = std::path::PathBuf::from(
                std::process::Command::new("git")
                    .args(["rev-parse", "--show-toplevel"])
                    .output()
                    .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
                    .unwrap_or_default(),
            )
            .join(".chump-locks/.wt-session-id");
            if let Ok(id) = std::fs::read_to_string(&wt_cache) {
                let id = id.trim().to_string();
                if !id.is_empty() {
                    return id;
                }
            }
            uuid::Uuid::new_v4().to_string()
        })
}

#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<String> = env::args().collect();
    let cmd = args.get(1).map(|s| s.as_str()).unwrap_or("help");

    match cmd {
        // ── ping ─────────────────────────────────────────────────────────────
        "ping" => match CoordClient::connect().await {
            Ok(c) if c.ping().await => {
                println!(
                    "[chump-coord] NATS OK ({})",
                    env::var("CHUMP_NATS_URL")
                        .unwrap_or_else(|_| chump_coord::DEFAULT_NATS_URL.to_string())
                );
                std::process::exit(0);
            }
            Ok(_) => {
                eprintln!("[chump-coord] NATS connected but ping failed");
                std::process::exit(1);
            }
            Err(e) => {
                eprintln!("[chump-coord] NATS unreachable: {}", e);
                std::process::exit(1);
            }
        },

        // ── claim ─────────────────────────────────────────────────────────────
        "claim" => {
            let gap_id = args.get(2).map(|s| s.as_str()).unwrap_or_else(|| {
                eprintln!("Usage: chump-coord claim <gap-id>");
                std::process::exit(2);
            });
            let sess = session_id();
            let files_env = env::var("CHUMP_COORD_FILES").unwrap_or_default();
            let files: Vec<&str> = files_env
                .split(',')
                .map(|s| s.trim())
                .filter(|s| !s.is_empty())
                .collect();

            match CoordClient::connect_or_skip().await {
                None => {
                    // NATS down — can't atomically claim; caller falls back to files.
                    // Exit 0 so gap-claim.sh continues with file-based lease.
                    eprintln!(
                        "[chump-coord] NATS unavailable — skipping atomic claim for {}",
                        gap_id
                    );
                    std::process::exit(0);
                }
                Some(c) => {
                    match c.try_claim_gap_with_files(gap_id, &sess, &files).await {
                        Ok(true) => {
                            println!(
                                "[chump-coord] CLAIMED {} (session={})",
                                gap_id,
                                &sess[..16.min(sess.len())]
                            );
                            // Also emit INTENT to JetStream for real-time fanout
                            let _ = c.emit_intent(&sess, gap_id, &files_env).await;

                            // CREDIBLE-254 (CREDIBLE-099 slice): also write this
                            // worker's presence record to the `chump_workers` KV
                            // bucket, pointed at the gap just claimed. Preserves
                            // `started_at` for a worker already registered (e.g.
                            // via spawn_worker_tool); synthesizes a fresh record
                            // otherwise. Non-fatal — presence storage never blocks
                            // the claim itself.
                            if let Err(e) = chump_coord::presence::update_presence_gap(
                                &c.workers_kv,
                                &sess,
                                Some(gap_id.to_string()),
                            )
                            .await
                            {
                                eprintln!(
                                    "[chump-coord] presence update failed (non-fatal): {}",
                                    e
                                );
                            }

                            std::process::exit(0);
                        }
                        Ok(false) => {
                            // Find out who holds it
                            let holder = c
                                .gap_claim(gap_id)
                                .await
                                .ok()
                                .flatten()
                                .map(|cl| cl.session_id)
                                .unwrap_or_else(|| "unknown".to_string());
                            eprintln!(
                                "[chump-coord] CONFLICT: {} already claimed by session '{}'",
                                gap_id,
                                &holder[..16.min(holder.len())]
                            );

                            std::process::exit(1);
                        }
                        Err(e) => {
                            eprintln!("[chump-coord] Claim error (falling back to file): {}", e);

                            // Exit 0 — file-based fallback should proceed
                            std::process::exit(0);
                        }
                    }
                }
            }
        }

        // ── release ───────────────────────────────────────────────────────────
        "release" => {
            let gap_id = args.get(2).map(|s| s.as_str()).unwrap_or_else(|| {
                eprintln!("Usage: chump-coord release <gap-id>");
                std::process::exit(2);
            });
            match CoordClient::connect_or_skip().await {
                None => {
                    eprintln!("[chump-coord] NATS unavailable — can't release {}", gap_id);
                    std::process::exit(0);
                }
                Some(c) => {
                    c.release_gap(gap_id).await?;
                    println!("[chump-coord] RELEASED {}", gap_id);
                }
            }
        }

        // ── merge-lock ────────────────────────────────────────────────────────
        // INFRA-7714 (INFRA-2252 slice): NATS KV CAS lock serializing the local
        // merge queue across worker machines on the mesh.
        //
        // Exit codes:
        //   0  acquire: lock won | release: cleared | status: printed
        //   1  acquire: lock held by another holder (CAS conflict — expected)
        //   2  usage error
        //   3  NATS unreachable — distinct from (1) so callers can tell
        //      "someone else is merging" from "can't reach the coordination
        //      layer at all" and fall back to file-lock accordingly.
        "merge-lock" => {
            let sub = args.get(2).map(|s| s.as_str()).unwrap_or_else(|| {
                eprintln!("Usage: chump-coord merge-lock {{acquire <holder>|release|status}}");
                std::process::exit(2);
            });
            match sub {
                "acquire" => {
                    let holder = args.get(3).map(|s| s.as_str()).unwrap_or_else(|| {
                        eprintln!("Usage: chump-coord merge-lock acquire <holder>");
                        std::process::exit(2);
                    });
                    match CoordClient::connect().await {
                        Err(e) => {
                            eprintln!("[chump-coord] merge-lock: NATS unreachable: {}", e);
                            std::process::exit(3);
                        }
                        Ok(c) => match c.try_acquire_merge_lock(holder).await {
                            Ok(true) => {
                                println!("[chump-coord] merge-lock ACQUIRED by {}", holder);
                                std::process::exit(0);
                            }
                            Ok(false) => {
                                let who = c
                                    .merge_lock_holder()
                                    .await
                                    .ok()
                                    .flatten()
                                    .map(|h| h.holder)
                                    .unwrap_or_else(|| "unknown".to_string());
                                eprintln!("[chump-coord] merge-lock CONFLICT: held by '{}'", who);
                                std::process::exit(1);
                            }
                            Err(e) => {
                                eprintln!("[chump-coord] merge-lock: NATS unreachable: {}", e);
                                std::process::exit(3);
                            }
                        },
                    }
                }
                "release" => match CoordClient::connect().await {
                    Err(e) => {
                        eprintln!("[chump-coord] merge-lock: NATS unreachable: {}", e);
                        std::process::exit(3);
                    }
                    Ok(c) => match c.release_merge_lock().await {
                        Ok(()) => {
                            println!("[chump-coord] merge-lock RELEASED");
                            std::process::exit(0);
                        }
                        Err(e) => {
                            eprintln!("[chump-coord] merge-lock: NATS unreachable: {}", e);
                            std::process::exit(3);
                        }
                    },
                },
                "status" => match CoordClient::connect().await {
                    Err(e) => {
                        eprintln!("[chump-coord] merge-lock: NATS unreachable: {}", e);
                        std::process::exit(3);
                    }
                    Ok(c) => match c.merge_lock_holder().await {
                        Ok(Some(h)) => {
                            println!(
                                "[chump-coord] merge-lock HELD by {} since {}",
                                h.holder, h.acquired_at
                            );
                        }
                        Ok(None) => println!("[chump-coord] merge-lock UNLOCKED"),
                        Err(e) => {
                            eprintln!("[chump-coord] merge-lock: NATS unreachable: {}", e);
                            std::process::exit(3);
                        }
                    },
                },
                _ => {
                    eprintln!("Usage: chump-coord merge-lock {{acquire <holder>|release|status}}");
                    std::process::exit(2);
                }
            }
        }

        // ── whois ─────────────────────────────────────────────────────────────
        // INFRA-274: per-gap NATS-side claim lookup. Returns the holding
        // session_id on stdout (so shell can capture it), or empty string
        // when no claim exists or NATS is unreachable.
        //
        // Exit codes:
        //   0  — printed (either a session_id or empty); caller treats as info
        //   2  — usage error (no gap-id arg)
        //
        // Used by gap-preflight.sh to detect cross-host claims that local
        // .chump-locks/ can't see.
        "whois" => {
            let gap_id = args.get(2).map(|s| s.as_str()).unwrap_or_else(|| {
                eprintln!("Usage: chump-coord whois <gap-id>");
                std::process::exit(2);
            });
            match CoordClient::connect_or_skip().await {
                None => {
                    // NATS unavailable — print empty so caller falls through
                    // to local-file check. Use stderr for the diagnostic so
                    // stdout stays parseable.
                    eprintln!("[chump-coord] NATS unavailable — whois inconclusive");
                    println!();
                }
                Some(c) => match c.gap_claim(gap_id).await {
                    Ok(Some(claim)) => {
                        // Print session_id on stdout (newline-terminated).
                        println!("{}", claim.session_id);
                    }
                    Ok(None) => {
                        println!();
                    }
                    Err(e) => {
                        eprintln!("[chump-coord] whois error: {}", e);
                        println!();
                    }
                },
            }
        }

        // ── status ────────────────────────────────────────────────────────────
        "status" => match CoordClient::connect_or_skip().await {
            None => {
                eprintln!("[chump-coord] NATS unavailable — no atomic claim status");
                std::process::exit(0);
            }
            Some(c) => {
                let claims = c.list_gap_claims().await.unwrap_or_default();
                if claims.is_empty() {
                    println!("[chump-coord] No active atomic gap claims in NATS KV.");
                } else {
                    println!("[chump-coord] Active gap claims ({}):", claims.len());
                    for (gap_id, claim) in &claims {
                        println!(
                            "  {:12}  session={:<20}  claimed={}",
                            gap_id,
                            &claim.session_id[..20.min(claim.session_id.len())],
                            claim.claimed_at
                        );
                        if !claim.files.is_empty() {
                            println!("             files: {}", claim.files.join(", "));
                        }
                    }
                }
            }
        },

        // ── emit ──────────────────────────────────────────────────────────────
        // Usage: chump-coord emit INTENT gap=COG-016 files=src/reflection.rs
        //        chump-coord emit DONE   gap=COG-016 commit=abc123
        //        chump-coord emit STUCK  gap=COG-016 reason="cargo check fails"
        "emit" => {
            let event_type = args.get(2).map(|s| s.to_uppercase()).unwrap_or_else(|| {
                eprintln!("Usage: chump-coord emit <TYPE> [key=value ...]");
                std::process::exit(2);
            });
            let sess = session_id();

            // Parse key=value pairs from remaining args
            let mut gap: Option<String> = None;
            let mut files: Option<String> = None;
            let mut reason: Option<String> = None;
            let mut commit: Option<String> = None;
            let mut kind: Option<String> = None;
            let mut to: Option<String> = None;

            for kv_arg in &args[3..] {
                if let Some((k, v)) = kv_arg.split_once('=') {
                    match k {
                        "gap" => gap = Some(v.to_string()),
                        "files" => files = Some(v.to_string()),
                        "reason" => reason = Some(v.to_string()),
                        "commit" => commit = Some(v.to_string()),
                        "kind" => kind = Some(v.to_string()),
                        "to" => to = Some(v.to_string()),
                        _ => {}
                    }
                }
            }

            let event = CoordEvent {
                event: event_type.clone(),
                session: sess,
                ts: chrono::Utc::now().to_rfc3339(),
                gap,
                files,
                reason,
                commit,
                kind,
                to,
            };

            match CoordClient::connect_or_skip().await {
                None => {
                    eprintln!("[chump-coord] NATS unavailable — event not published to JetStream");
                    std::process::exit(0);
                }
                Some(c) => {
                    c.emit(event).await?;
                    println!("[chump-coord] EMITTED {}", event_type);
                }
            }
        }

        // ── watch ─────────────────────────────────────────────────────────────
        "watch" => {
            use futures::StreamExt;

            match CoordClient::connect_or_skip().await {
                None => {
                    eprintln!("[chump-coord] NATS unavailable — cannot watch events");
                    std::process::exit(1);
                }
                Some(c) => {
                    println!("[chump-coord] Watching chump.events.> (ctrl-c to stop)");
                    let mut sub = c.nats.subscribe("chump.events.>").await?;
                    while let Some(msg) = sub.next().await {
                        let subject = &msg.subject;
                        let payload = String::from_utf8_lossy(&msg.payload);
                        if let Ok(event) = serde_json::from_str::<CoordEvent>(&payload) {
                            println!(
                                "{:25}  {:<12}  session={:<16}  gap={:<12}  {}",
                                event.ts,
                                event.event,
                                &event.session[..16.min(event.session.len())],
                                event.gap.as_deref().unwrap_or("—"),
                                event
                                    .reason
                                    .as_deref()
                                    .or(event.commit.as_deref())
                                    .or(event.files.as_deref())
                                    .unwrap_or("")
                            );
                        } else {
                            println!("{}: {}", subject, payload);
                        }
                    }
                }
            }
        }

        // ── react ─────────────────────────────────────────────────────────────
        // RESILIENT-334: subscribe to the bus and ACT on WORK_POSTED events as
        // the primary coordination path (atomic claim triggered by the event,
        // not by polling `work-board list` on a timer).
        //
        // Usage:
        //   chump-coord react [--task-class <class>] [--once] [--timeout-secs N]
        //
        //   --task-class <class>  only claim subtasks whose requirement.task_class
        //                         matches exactly (default: claim any open subtask)
        //   --once                exit after the first successful claim (or timeout)
        //   --timeout-secs N      give up waiting for an event after N seconds
        //                         (default: run forever)
        "react" => {
            use chump_coord::nats_primary::{subscribe_events_with_session, EventFilter};
            use chump_coord::worker::{react_to_event, ReactOutcome};

            let mut task_class: Option<String> = None;
            let mut once = false;
            let mut timeout_secs: Option<u64> = None;
            let mut i = 2;
            while i < args.len() {
                match args[i].as_str() {
                    "--task-class" => {
                        i += 1;
                        task_class = args.get(i).cloned();
                    }
                    "--once" => once = true,
                    "--timeout-secs" => {
                        i += 1;
                        timeout_secs = args.get(i).and_then(|s| s.parse().ok());
                    }
                    _ => {}
                }
                i += 1;
            }

            let sess = session_id();
            let client = match CoordClient::connect_or_skip().await {
                Some(c) => c,
                None => {
                    eprintln!("[chump-coord react] NATS unavailable — cannot react to bus events");
                    std::process::exit(1);
                }
            };

            // WORK_POSTED only ever reaches JetStream, never ambient.jsonl
            // (work_board has no file-fallback mirror — see work_board.rs
            // module docs), so the file-only default (CHUMP_A2A_LAYER=0)
            // would silently never see it. Force the NATS-primary path
            // unless the caller already opted in explicitly.
            if env::var("CHUMP_A2A_LAYER").is_err() {
                env::set_var("CHUMP_A2A_LAYER", "1");
            }

            // NATS subject filtering for `EventFilter::Kind` assumes the
            // one-segment `chump.events.<kind>` convention; work-board events
            // publish on the multi-segment `chump.events.work_board.posted`
            // subject, so subscribe to everything and post-filter by kind
            // (react_to_event already ignores anything that isn't WORK_POSTED).
            let mut stream = subscribe_events_with_session(EventFilter::All, Some(sess.clone()))
                .await
                .map_err(|e| anyhow::anyhow!("subscribe failed: {e}"))?;

            println!(
                "[chump-coord react] session={sess} listening for WORK_POSTED (task_class={})",
                task_class.as_deref().unwrap_or("any")
            );

            loop {
                let next = match timeout_secs {
                    Some(secs) => {
                        match tokio::time::timeout(
                            std::time::Duration::from_secs(secs),
                            stream.next(),
                        )
                        .await
                        {
                            Ok(v) => v,
                            Err(_) => {
                                eprintln!("[chump-coord react] timed out after {secs}s, exiting");
                                break;
                            }
                        }
                    }
                    None => stream.next().await,
                };

                let Some(event) = next else {
                    eprintln!("[chump-coord react] event stream closed, exiting");
                    break;
                };

                let task_class_ref = task_class.as_deref();
                let outcome = react_to_event(&client, &event, &sess, |subtask| {
                    task_class_ref.is_none_or(|tc| subtask.requirement.task_class == tc)
                })
                .await?;

                match outcome {
                    ReactOutcome::Ignored | ReactOutcome::Skipped => {}
                    ReactOutcome::LostRace => {
                        println!("[chump-coord react] lost claim race, still listening");
                    }
                    ReactOutcome::Claimed(subtask) => {
                        println!(
                            "[chump-coord react] CLAIMED {} (parent_gap={}) via bus event",
                            subtask.subtask_id, subtask.parent_gap
                        );
                        if once {
                            break;
                        }
                    }
                }
            }
        }

        // ── work-board ────────────────────────────────────────────────────────
        // Usage:
        //   chump-coord work-board post <parent-gap> <task-class> "<title>" [--decomposable] [--description "..."] [--est-secs N]
        //   chump-coord work-board list [--status open|claimed|completed|failed|all]
        //   chump-coord work-board claim <subtask-id>
        //   chump-coord work-board complete <subtask-id> [--commit <sha-or-pr>]
        //   chump-coord work-board fail <subtask-id> --reason "..."
        //   chump-coord work-board show <subtask-id>
        "work-board" => {
            let sub = args.get(2).map(|s| s.as_str()).unwrap_or("");
            let client = match CoordClient::connect_or_skip().await {
                Some(c) => c,
                None => {
                    eprintln!(
                        "[chump-coord] NATS unavailable — work-board requires a reachable broker"
                    );
                    std::process::exit(1);
                }
            };
            match sub {
                "post" => {
                    let parent_gap = args.get(3).cloned().unwrap_or_else(|| {
                        eprintln!("Usage: chump-coord work-board post <parent-gap> <task-class> \"<title>\" [flags…]");
                        std::process::exit(2);
                    });
                    let task_class = args.get(4).cloned().unwrap_or_else(|| {
                        eprintln!("Missing <task-class>");
                        std::process::exit(2);
                    });
                    let title = args.get(5).cloned().unwrap_or_else(|| {
                        eprintln!("Missing \"<title>\"");
                        std::process::exit(2);
                    });
                    // Optional flags after the positionals.
                    let mut description = String::new();
                    let mut decomposable = false;
                    let mut est_secs: Option<u32> = None;
                    let mut required_model: Option<String> = None;
                    let mut min_vram: Option<u32> = None;
                    let mut i = 6;
                    while i < args.len() {
                        match args[i].as_str() {
                            "--decomposable" => decomposable = true,
                            "--description" => {
                                i += 1;
                                description = args.get(i).cloned().unwrap_or_default();
                            }
                            "--est-secs" => {
                                i += 1;
                                est_secs = args.get(i).and_then(|s| s.parse().ok());
                            }
                            "--model" => {
                                i += 1;
                                required_model = args.get(i).cloned();
                            }
                            "--min-vram-gb" => {
                                i += 1;
                                min_vram = args.get(i).and_then(|s| s.parse().ok());
                            }
                            other => {
                                eprintln!("Unknown flag: {}", other);
                                std::process::exit(2);
                            }
                        }
                        i += 1;
                    }
                    let req = Requirement {
                        task_class,
                        required_model_family: required_model,
                        min_vram_gb: min_vram,
                        min_inference_speed_tok_per_sec: None,
                        estimated_duration_sec: est_secs,
                        decomposable,
                    };
                    let mut subtask = Subtask::new(&parent_gap, &title, &session_id(), req);
                    subtask.description = description;
                    client.post_subtask(&subtask).await?;
                    println!("{}", subtask.subtask_id);
                }
                "list" => {
                    let mut filter: Option<SubtaskStatus> = Some(SubtaskStatus::Open);
                    let mut i = 3;
                    while i < args.len() {
                        match args[i].as_str() {
                            "--status" => {
                                i += 1;
                                filter = match args.get(i).map(|s| s.as_str()) {
                                    Some("open") => Some(SubtaskStatus::Open),
                                    Some("claimed") => Some(SubtaskStatus::Claimed),
                                    Some("completed") => Some(SubtaskStatus::Completed),
                                    Some("failed") => Some(SubtaskStatus::Failed),
                                    Some("all") => None,
                                    Some(other) => {
                                        eprintln!("Unknown status: {}", other);
                                        std::process::exit(2);
                                    }
                                    None => Some(SubtaskStatus::Open),
                                };
                            }
                            other => {
                                eprintln!("Unknown flag: {}", other);
                                std::process::exit(2);
                            }
                        }
                        i += 1;
                    }
                    let subtasks = client.list_subtasks(filter).await?;
                    if subtasks.is_empty() {
                        println!("[chump-coord] No subtasks match.");
                    } else {
                        println!(
                            "{:<22} {:<14} {:<10} {:<22} title",
                            "subtask_id", "parent_gap", "status", "task_class"
                        );
                        for s in subtasks {
                            println!(
                                "{:<22} {:<14} {:<10} {:<22} {}",
                                s.subtask_id,
                                s.parent_gap,
                                format!("{:?}", s.status).to_lowercase(),
                                s.requirement.task_class,
                                s.title
                            );
                        }
                    }
                }
                "claim" => {
                    let id = args.get(3).cloned().unwrap_or_else(|| {
                        eprintln!("Usage: chump-coord work-board claim <subtask-id>");
                        std::process::exit(2);
                    });
                    let sess = session_id();
                    match client.claim_subtask(&id, &sess).await? {
                        Ok(s) => {
                            println!(
                                "[chump-coord] CLAIMED {} (parent={}, task_class={})",
                                s.subtask_id, s.parent_gap, s.requirement.task_class
                            );
                        }
                        Err(miss) => {
                            print_transition_miss("claim", &id, &miss);
                            std::process::exit(1);
                        }
                    }
                }
                "complete" => {
                    let id = args.get(3).cloned().unwrap_or_else(|| {
                        eprintln!(
                            "Usage: chump-coord work-board complete <subtask-id> [--commit <sha>]"
                        );
                        std::process::exit(2);
                    });
                    let mut commit: Option<String> = None;
                    let mut i = 4;
                    while i < args.len() {
                        if args[i] == "--commit" {
                            i += 1;
                            commit = args.get(i).cloned();
                        }
                        i += 1;
                    }
                    let sess = session_id();
                    match client
                        .complete_subtask(&id, &sess, commit.as_deref())
                        .await?
                    {
                        Ok(s) => println!(
                            "[chump-coord] COMPLETED {} (parent={})",
                            s.subtask_id, s.parent_gap
                        ),
                        Err(miss) => {
                            print_transition_miss("complete", &id, &miss);
                            std::process::exit(1);
                        }
                    }
                }
                "fail" => {
                    let id = args.get(3).cloned().unwrap_or_else(|| {
                        eprintln!(
                            "Usage: chump-coord work-board fail <subtask-id> --reason \"...\""
                        );
                        std::process::exit(2);
                    });
                    let mut reason = String::new();
                    let mut i = 4;
                    while i < args.len() {
                        if args[i] == "--reason" {
                            i += 1;
                            reason = args.get(i).cloned().unwrap_or_default();
                        }
                        i += 1;
                    }
                    if reason.is_empty() {
                        eprintln!("--reason is required");
                        std::process::exit(2);
                    }
                    let sess = session_id();
                    match client.fail_subtask(&id, &sess, &reason).await? {
                        Ok(s) => {
                            println!("[chump-coord] FAILED {} (reason={})", s.subtask_id, reason)
                        }
                        Err(miss) => {
                            print_transition_miss("fail", &id, &miss);
                            std::process::exit(1);
                        }
                    }
                }
                "show" => {
                    let id = args.get(3).cloned().unwrap_or_else(|| {
                        eprintln!("Usage: chump-coord work-board show <subtask-id>");
                        std::process::exit(2);
                    });
                    match client.get_subtask(&id).await? {
                        Some(s) => println!("{}", serde_json::to_string_pretty(&s)?),
                        None => {
                            eprintln!("[chump-coord] not found: {}", id);
                            std::process::exit(1);
                        }
                    }
                }
                _ => {
                    eprintln!(
                        "Usage: chump-coord work-board {{post|list|claim|complete|fail|show}} …"
                    );
                    std::process::exit(2);
                }
            }
        }

        // ── help-request (FLEET-010) ─────────────────────────────────────────
        // Usage:
        //   chump-coord help-request post <blocker-type> "<description>" \
        //       [--parent-subtask SUBTASK-…] [--parent-gap FLEET-…] \
        //       [--needed-capability "..."] [--blocking]
        //   chump-coord help-request list [--status open|claimed|completed|failed|all] \
        //       [--parent-subtask SUBTASK-…] [--parent-gap FLEET-…]
        //   chump-coord help-request claim    <help-id>
        //   chump-coord help-request complete <help-id> [--resolution "..."]
        //   chump-coord help-request fail     <help-id> --reason "..."
        //   chump-coord help-request show     <help-id>
        "help-request" => {
            let sub = args.get(2).map(|s| s.as_str()).unwrap_or("");
            let client = match CoordClient::connect_or_skip().await {
                Some(c) => c,
                None => {
                    eprintln!(
                        "[chump-coord] NATS unavailable — help-request requires a reachable broker"
                    );
                    std::process::exit(1);
                }
            };
            match sub {
                "post" => {
                    let blocker_arg = args.get(3).cloned().unwrap_or_else(|| {
                        eprintln!("Usage: chump-coord help-request post <blocker-type> \"<description>\" [flags…]");
                        eprintln!("  blocker-type: timeout | missing_capability | unknown_task_class | other");
                        std::process::exit(2);
                    });
                    let description = args.get(4).cloned().unwrap_or_else(|| {
                        eprintln!("Missing \"<description>\"");
                        std::process::exit(2);
                    });
                    let blocker_type = match blocker_arg.as_str() {
                        "timeout" => BlockerType::Timeout,
                        "missing_capability" => BlockerType::MissingCapability,
                        "unknown_task_class" => BlockerType::UnknownTaskClass,
                        "other" => BlockerType::Other,
                        other => {
                            eprintln!(
                                "Unknown blocker-type: {} (expected timeout|missing_capability|unknown_task_class|other)",
                                other
                            );
                            std::process::exit(2);
                        }
                    };
                    let mut req = HelpRequest::new(blocker_type, &description, &session_id());
                    let mut i = 5;
                    while i < args.len() {
                        match args[i].as_str() {
                            "--parent-subtask" => {
                                i += 1;
                                if let Some(v) = args.get(i) {
                                    req.parent_subtask = Some(v.clone());
                                }
                            }
                            "--parent-gap" => {
                                i += 1;
                                if let Some(v) = args.get(i) {
                                    req.parent_gap = Some(v.clone());
                                }
                            }
                            "--needed-capability" => {
                                i += 1;
                                if let Some(v) = args.get(i) {
                                    req.needed_capability = Some(v.clone());
                                }
                            }
                            "--blocking" => req.blocking = true,
                            other => {
                                eprintln!("Unknown flag: {}", other);
                                std::process::exit(2);
                            }
                        }
                        i += 1;
                    }
                    client.post_help_request(&req).await?;
                    println!("{}", req.help_id);
                }
                "list" => {
                    let mut filter_status: Option<HelpStatus> = Some(HelpStatus::Open);
                    let mut filter_parent_subtask: Option<String> = None;
                    let mut filter_parent_gap: Option<String> = None;
                    let mut i = 3;
                    while i < args.len() {
                        match args[i].as_str() {
                            "--status" => {
                                i += 1;
                                filter_status = match args.get(i).map(|s| s.as_str()) {
                                    Some("open") => Some(HelpStatus::Open),
                                    Some("claimed") => Some(HelpStatus::Claimed),
                                    Some("completed") => Some(HelpStatus::Completed),
                                    Some("failed") => Some(HelpStatus::Failed),
                                    Some("all") => None,
                                    Some(other) => {
                                        eprintln!("Unknown status: {}", other);
                                        std::process::exit(2);
                                    }
                                    None => Some(HelpStatus::Open),
                                };
                            }
                            "--parent-subtask" => {
                                i += 1;
                                filter_parent_subtask = args.get(i).cloned();
                            }
                            "--parent-gap" => {
                                i += 1;
                                filter_parent_gap = args.get(i).cloned();
                            }
                            other => {
                                eprintln!("Unknown flag: {}", other);
                                std::process::exit(2);
                            }
                        }
                        i += 1;
                    }
                    let reqs = client
                        .list_help_requests(
                            filter_status,
                            filter_parent_subtask.as_deref(),
                            filter_parent_gap.as_deref(),
                        )
                        .await?;
                    if reqs.is_empty() {
                        println!("[chump-coord] No help requests match.");
                    } else {
                        println!(
                            "{:<14} {:<10} {:<22} {:<14} {:<14} description",
                            "help_id", "status", "blocker_type", "parent_gap", "parent_sub"
                        );
                        for r in reqs {
                            println!(
                                "{:<14} {:<10} {:<22} {:<14} {:<14} {}",
                                r.help_id,
                                format!("{:?}", r.status).to_lowercase(),
                                format!("{:?}", r.blocker_type).to_lowercase(),
                                r.parent_gap.unwrap_or_else(|| "—".to_string()),
                                r.parent_subtask.unwrap_or_else(|| "—".to_string()),
                                r.description
                            );
                        }
                    }
                }
                "claim" => {
                    let id = args.get(3).cloned().unwrap_or_else(|| {
                        eprintln!("Usage: chump-coord help-request claim <help-id>");
                        std::process::exit(2);
                    });
                    let sess = session_id();
                    match client.claim_help_request(&id, &sess).await? {
                        Ok(r) => println!(
                            "[chump-coord] CLAIMED {} (blocker={:?}, description={})",
                            r.help_id, r.blocker_type, r.description
                        ),
                        Err(miss) => {
                            print_transition_miss("claim", &id, &miss);
                            std::process::exit(1);
                        }
                    }
                }
                "complete" => {
                    let id = args.get(3).cloned().unwrap_or_else(|| {
                        eprintln!("Usage: chump-coord help-request complete <help-id> [--resolution \"…\"]");
                        std::process::exit(2);
                    });
                    let mut resolution: Option<String> = None;
                    let mut i = 4;
                    while i < args.len() {
                        if args[i] == "--resolution" {
                            i += 1;
                            resolution = args.get(i).cloned();
                        }
                        i += 1;
                    }
                    let sess = session_id();
                    match client
                        .complete_help_request(&id, &sess, resolution.as_deref())
                        .await?
                    {
                        Ok(r) => println!(
                            "[chump-coord] COMPLETED {} (resolution={})",
                            r.help_id,
                            r.resolution.as_deref().unwrap_or("—")
                        ),
                        Err(miss) => {
                            print_transition_miss("complete", &id, &miss);
                            std::process::exit(1);
                        }
                    }
                }
                "fail" => {
                    let id = args.get(3).cloned().unwrap_or_else(|| {
                        eprintln!("Usage: chump-coord help-request fail <help-id> --reason \"…\"");
                        std::process::exit(2);
                    });
                    let mut reason = String::new();
                    let mut i = 4;
                    while i < args.len() {
                        if args[i] == "--reason" {
                            i += 1;
                            reason = args.get(i).cloned().unwrap_or_default();
                        }
                        i += 1;
                    }
                    if reason.is_empty() {
                        eprintln!("--reason is required");
                        std::process::exit(2);
                    }
                    let sess = session_id();
                    match client.fail_help_request(&id, &sess, &reason).await? {
                        Ok(r) => println!("[chump-coord] FAILED {} (reason={})", r.help_id, reason),
                        Err(miss) => {
                            print_transition_miss("fail", &id, &miss);
                            std::process::exit(1);
                        }
                    }
                }
                "show" => {
                    let id = args.get(3).cloned().unwrap_or_else(|| {
                        eprintln!("Usage: chump-coord help-request show <help-id>");
                        std::process::exit(2);
                    });
                    match client.get_help_request(&id).await? {
                        Some(r) => println!("{}", serde_json::to_string_pretty(&r)?),
                        None => {
                            eprintln!("[chump-coord] not found: {}", id);
                            std::process::exit(1);
                        }
                    }
                }
                _ => {
                    eprintln!(
                        "Usage: chump-coord help-request {{post|list|claim|complete|fail|show}} …"
                    );
                    std::process::exit(2);
                }
            }
        }

        // ── assign (FLEET-034 daemon) ────────────────────────────────────────
        // Watches state.db and publishes routed work envelopes to
        // chump.work.<priority>.<class>.<machine>. Exits cleanly when NATS
        // is unreachable so workers fall back to their pull loop.
        //
        // Usage: chump-coord assign [--poll-secs N]
        // Env:   CHUMP_REPO_ROOT (override repo root), CHUMP_NATS_URL
        "assign" => {
            use chump_coord::assign::{run_assign_daemon, DEFAULT_POLL_INTERVAL_S};
            let mut poll_secs = DEFAULT_POLL_INTERVAL_S;
            let mut i = 2;
            while i < args.len() {
                if args[i] == "--poll-secs" {
                    i += 1;
                    if let Some(v) = args.get(i).and_then(|s| s.parse().ok()) {
                        poll_secs = v;
                    }
                }
                i += 1;
            }
            let repo_root = std::env::var("CHUMP_REPO_ROOT")
                .map(std::path::PathBuf::from)
                .unwrap_or_else(|_| {
                    std::process::Command::new("git")
                        .args(["rev-parse", "--show-toplevel"])
                        .output()
                        .ok()
                        .and_then(|o| {
                            String::from_utf8(o.stdout)
                                .ok()
                                .map(|s| s.trim().to_string())
                        })
                        .map(std::path::PathBuf::from)
                        .unwrap_or_else(|| std::path::PathBuf::from("."))
                });
            run_assign_daemon(repo_root, std::time::Duration::from_secs(poll_secs)).await?;
        }

        // ── worker (FLEET-034 subscriber stub) ───────────────────────────────
        // Subscribes to chump.work.> filtered by worker capability tags.
        // First worker to atomically claim wins; ack-timeout (60s default)
        // is honored implicitly because the claim is the ack.
        //
        // Env: WORKER_SKILLS (csv), WORKER_MACHINE, WORKER_BACKEND, CHUMP_SESSION_ID
        // Usage: chump-coord worker [--once] [--subjects chump.work.P0.>,...]
        "worker" => {
            use chump_coord::assign::{worker_accepts, WorkEnvelope, WORK_SUBJECT_PREFIX};
            use futures::StreamExt;

            let once = args.iter().any(|a| a == "--once");
            let mut subjects: Vec<String> = Vec::new();
            let mut i = 2;
            while i < args.len() {
                if args[i] == "--subjects" {
                    i += 1;
                    if let Some(v) = args.get(i) {
                        subjects = v.split(',').map(|s| s.trim().to_string()).collect();
                    }
                }
                i += 1;
            }
            if subjects.is_empty() {
                subjects.push(format!("{}.>", WORK_SUBJECT_PREFIX));
            }

            let skills: Vec<String> = std::env::var("WORKER_SKILLS")
                .unwrap_or_default()
                .split(',')
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect();
            let machine = std::env::var("WORKER_MACHINE").unwrap_or_default();
            let backend = std::env::var("WORKER_BACKEND").unwrap_or_default();
            let sess = session_id();

            let client = match CoordClient::connect_or_skip().await {
                Some(c) => c,
                None => {
                    eprintln!(
                        "[chump-coord worker] NATS unavailable — falling back to pull loop (worker.sh)"
                    );
                    std::process::exit(0);
                }
            };

            // Subscribe to all configured subjects.
            let mut subs = Vec::new();
            for s in &subjects {
                eprintln!("[chump-coord worker] subscribing: {}", s);
                subs.push(client.nats.subscribe(s.clone()).await?);
            }
            // Round-robin merge: poll each in turn.
            'outer: loop {
                for sub in subs.iter_mut() {
                    let msg = match tokio::time::timeout(
                        std::time::Duration::from_millis(500),
                        sub.next(),
                    )
                    .await
                    {
                        Ok(Some(m)) => m,
                        _ => continue,
                    };
                    let env: WorkEnvelope = match serde_json::from_slice(&msg.payload) {
                        Ok(e) => e,
                        Err(_) => continue,
                    };
                    if !worker_accepts(&env, &skills, &machine, &backend) {
                        continue;
                    }
                    // Try to claim — winning the CAS is our ack.
                    match client.try_claim_gap(&env.gap_id, &sess).await {
                        Ok(true) => {
                            println!(
                                "{}\t{}\t{}\t{}",
                                env.gap_id, env.priority, env.class, env.machine
                            );
                            // CREDIBLE-254 (CREDIBLE-099 slice): keep the
                            // worker's presence record pointed at the gap it
                            // just won. Non-fatal.
                            if let Err(e) = chump_coord::presence::update_presence_gap(
                                &client.workers_kv,
                                &sess,
                                Some(env.gap_id.clone()),
                            )
                            .await
                            {
                                eprintln!(
                                    "[chump-coord worker] presence update failed (non-fatal): {}",
                                    e
                                );
                            }
                            if once {
                                break 'outer;
                            }
                        }
                        Ok(false) => {
                            // Lost the race — another worker won.
                        }
                        Err(e) => {
                            eprintln!("[chump-coord worker] claim error: {}", e);
                        }
                    }
                }
                if once {
                    // Drained subscriptions with no claim — exit cleanly.
                    break;
                }
            }
        }

        // ── workers ───────────────────────────────────────────────────────────
        // CREDIBLE-257 (CREDIBLE-099 slice): harness-neutral verb to list
        // registered workers with their live state. Reads the `chump_workers`
        // NATS-KV bucket (CREDIBLE-246) and cross-references
        // `.chump-locks/ambient.jsonl` (kind=gap_shipped) for today's ship count.
        "workers" => {
            let json_out = args.iter().any(|a| a == "--json");

            let client = match CoordClient::connect_or_skip().await {
                Some(c) => c,
                None => {
                    eprintln!("[chump-coord workers] NATS unavailable — no presence data");
                    if json_out {
                        println!("[]");
                    }
                    std::process::exit(0);
                }
            };

            let records = client.list_worker_presence().await.unwrap_or_default();

            let ambient_path = std::path::PathBuf::from(
                env::var("CHUMP_AMBIENT_LOG")
                    .unwrap_or_else(|_| ".chump-locks/ambient.jsonl".to_string()),
            );
            let ships_today = chump_coord::presence::ships_today_counts(&ambient_path);

            let now = chrono::Utc::now();
            if json_out {
                let rows: Vec<serde_json::Value> = records
                    .iter()
                    .map(|p| {
                        let heartbeat_age = now.signed_duration_since(p.updated_at).num_seconds();
                        serde_json::json!({
                            "worker_id": p.worker_id,
                            "backend": p.backend,
                            "machine": p.machine,
                            "skills": p.skills,
                            "current_gap": p.current_gap,
                            "status": p.status,
                            "heartbeat_age_secs": heartbeat_age,
                            "ships_today": ships_today.get(&p.worker_id).copied().unwrap_or(0),
                        })
                    })
                    .collect();
                println!(
                    "{}",
                    serde_json::to_string_pretty(&rows).unwrap_or_else(|_| "[]".to_string())
                );
            } else if records.is_empty() {
                println!("[chump-coord workers] no registered workers");
            } else {
                println!(
                    "{:<28} {:<10} {:<14} {:<20} {:<18} {:>10} {:>6}",
                    "WORKER_ID", "BACKEND", "MACHINE", "SKILLS", "CURRENT_GAP", "HB_AGE_S", "SHIPS"
                );
                for p in &records {
                    let heartbeat_age = now.signed_duration_since(p.updated_at).num_seconds();
                    println!(
                        "{:<28} {:<10} {:<14} {:<20} {:<18} {:>10} {:>6}",
                        p.worker_id,
                        p.backend,
                        p.machine.as_deref().unwrap_or("-"),
                        if p.skills.is_empty() {
                            "-".to_string()
                        } else {
                            p.skills.join(",")
                        },
                        p.current_gap.as_deref().unwrap_or("-"),
                        heartbeat_age,
                        ships_today.get(&p.worker_id).copied().unwrap_or(0),
                    );
                }
            }
        }

        // ── scratch ───────────────────────────────────────────────────────────
        // INFRA-1826: file-backed scratchpad get/set/cas for A2A seed keys.
        // Uses .chump-locks/scratch/<key>.json; no NATS required.
        "scratch" => {
            use chump_coord::scratchpad;
            let sub = args.get(2).map(|s| s.as_str()).unwrap_or("help");
            match sub {
                "get" => {
                    let key = args.get(3).map(|s| s.as_str()).unwrap_or_else(|| {
                        eprintln!("Usage: chump-coord scratch get <key>");
                        std::process::exit(2);
                    });
                    match scratchpad::get(key).await {
                        Ok(Some(v)) => println!("{}", v),
                        Ok(None) => {
                            // Absent or expired — exit 1 so scripts can test
                            eprintln!("[scratch] key '{}' is unset or expired", key);
                            std::process::exit(1);
                        }
                        Err(e) => {
                            eprintln!("[scratch] get error: {}", e);
                            std::process::exit(2);
                        }
                    }
                }
                "set" => {
                    let key = args.get(3).map(|s| s.as_str()).unwrap_or_else(|| {
                        eprintln!("Usage: chump-coord scratch set <key> <value>");
                        std::process::exit(2);
                    });
                    let raw = args.get(4).map(|s| s.as_str()).unwrap_or_else(|| {
                        eprintln!("Usage: chump-coord scratch set <key> <value>");
                        std::process::exit(2);
                    });
                    // Accept JSON or bare string
                    let value: serde_json::Value = serde_json::from_str(raw)
                        .unwrap_or_else(|_| serde_json::Value::String(raw.to_string()));
                    match scratchpad::set(key, value).await {
                        Ok(()) => println!("[scratch] set '{}' OK", key),
                        Err(e) => {
                            eprintln!("[scratch] set error: {}", e);
                            std::process::exit(2);
                        }
                    }
                }
                "cas" => {
                    // Usage: chump-coord scratch cas <key> <expected> <new>
                    // Pass 'null' (bare) for expected when key is unset.
                    let key = args.get(3).map(|s| s.as_str()).unwrap_or_else(|| {
                        eprintln!("Usage: chump-coord scratch cas <key> <expected> <new>");
                        std::process::exit(2);
                    });
                    let raw_expected = args.get(4).map(|s| s.as_str()).unwrap_or_else(|| {
                        eprintln!("Usage: chump-coord scratch cas <key> <expected> <new>");
                        std::process::exit(2);
                    });
                    let raw_new = args.get(5).map(|s| s.as_str()).unwrap_or_else(|| {
                        eprintln!("Usage: chump-coord scratch cas <key> <expected> <new>");
                        std::process::exit(2);
                    });
                    let expected: serde_json::Value = serde_json::from_str(raw_expected)
                        .unwrap_or_else(|_| serde_json::Value::String(raw_expected.to_string()));
                    let new: serde_json::Value = serde_json::from_str(raw_new)
                        .unwrap_or_else(|_| serde_json::Value::String(raw_new.to_string()));
                    match scratchpad::cas(key, expected, new).await {
                        Ok(()) => println!("[scratch] cas '{}' OK", key),
                        Err(chump_coord::scratchpad::ScratchError::CASConflict {
                            key,
                            expected,
                            actual,
                        }) => {
                            eprintln!(
                                "[scratch] CAS conflict on '{}': expected='{}' actual='{}'",
                                key, expected, actual
                            );
                            std::process::exit(3); // distinct exit for CAS conflict
                        }
                        Err(e) => {
                            eprintln!("[scratch] cas error: {}", e);
                            std::process::exit(2);
                        }
                    }
                }
                "list" => {
                    // List all known seed keys and their current values
                    for sk in scratchpad::seed_keys() {
                        match scratchpad::get(sk.key).await {
                            Ok(Some(v)) => println!("{} = {}", sk.key, v),
                            Ok(None) => println!("{} = <unset>", sk.key),
                            Err(e) => println!("{} = <error: {}>", sk.key, e),
                        }
                    }
                }
                _ => {
                    eprintln!(
                        r#"chump-coord scratch — file-backed A2A scratchpad (INFRA-1826)

USAGE
  chump-coord scratch get <key>
  chump-coord scratch set <key> <value>       (LWW keys only; use cas for CAS-required)
  chump-coord scratch cas <key> <expected> <new>
  chump-coord scratch list

KEYS
  main.head.sha              CASRequired (cas only)
  fleet.size                 LastWriterWins
  pillar.focus               LastWriterWins
  last_known_good.chump_binary  CASRequired (cas only)
  red_letter.last_ts         LastWriterWins

EXIT CODES
  0   success
  1   key absent or expired (get)
  2   usage / key unknown / I/O error
  3   CAS conflict (cas)

ENVIRONMENT
  CHUMP_SCRATCH_DIR  override storage dir (default: .chump-locks/scratch/)
"#
                    );
                }
            }
        }

        // ── help / default ────────────────────────────────────────────────────
        _ => {
            eprintln!(
                r#"chump-coord — NATS atomic coordination layer (Phase 1)

COMMANDS
  ping                       Check NATS reachability (exit 0 = up)
  claim <gap-id>             Atomic CAS claim (exit 0 = won, 1 = conflict)
  release <gap-id>           Release gap claim
  status                     Show all active NATS KV claims
  emit <TYPE> [key=value …]  Publish event (TYPE: INTENT DONE STUCK WARN ALERT)
  watch                      Stream live events from chump.events.>
  scratch get|set|cas <key>  File-backed scratchpad for A2A seed keys (INFRA-1826)
  work-board <sub> [args …]  FLEET-008 shared subtask queue
                             post <parent-gap> <task-class> "<title>" [--decomposable] [--description "..."] [--est-secs N] [--model <fam>] [--min-vram-gb N]
                             list   [--status open|claimed|completed|failed|all]
                             claim    <subtask-id>
                             complete <subtask-id> [--commit <sha-or-pr>]
                             fail     <subtask-id> --reason "..."
                             show     <subtask-id>
  assign [--poll-secs N]     FLEET-034 push-routing daemon (watches state.db,
                             publishes to chump.work.<priority>.<class>.<machine>;
                             exits cleanly if NATS unreachable so workers fall back to pull)
  worker [--once] [--subjects CSV]
                             FLEET-034 NATS subscriber — first-ack-wins via atomic claim.
                             Reads WORKER_SKILLS, WORKER_MACHINE, WORKER_BACKEND from env.
  workers [--json]           CREDIBLE-257 — list registered workers + live state
                             (worker_id, backend, machine, skills, current_gap,
                             heartbeat_age_secs, ships_today) from chump_workers KV
                             (CREDIBLE-246) cross-referenced with ambient.jsonl.
  help-request <sub> [args …] FLEET-010 help-seeking protocol
                             post <blocker-type> "<description>" [--parent-subtask SUBTASK-…] [--parent-gap FLEET-…] [--needed-capability "…"] [--blocking]
                                  blocker-type: timeout|missing_capability|unknown_task_class|other
                             list   [--status open|claimed|completed|failed|all] [--parent-subtask …] [--parent-gap …]
                             claim    <help-id>
                             complete <help-id> [--resolution "…"]
                             fail     <help-id> --reason "…"
                             show     <help-id>

ENVIRONMENT
  CHUMP_NATS_URL             NATS server URL (default: nats://127.0.0.1:4222)
  CHUMP_SESSION_ID           Session identity (override)
  CHUMP_COORD_FILES          Comma-separated files for claim (optional)
  CHUMP_GAP_CLAIM_TTL_SECS   Claim TTL seconds (default: 14400 = 4h)
  CHUMP_NATS_TIMEOUT_MS      Connect timeout ms (default: 500)

INTEGRATION
  gap-claim.sh calls 'chump-coord claim' before writing file leases.
  If NATS is unreachable, exit 0 is returned and file-based leases proceed.

  gap-preflight.sh can call 'chump-coord status' to check atomic claims.
  broadcast.sh calls 'chump-coord emit' alongside ambient.jsonl writes.
"#
            );
        }
    }

    Ok(())
}
