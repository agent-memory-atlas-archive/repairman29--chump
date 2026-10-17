//! ZERO-WASTE-133: per-tool-call timeout for headless agents, plus a watchdog
//! for a single agent tool call that outlives it.
//!
//! Receipt (2026-10-16, cuphead): one Bash tool call of a headless repair
//! agent (a `grep` that Claude Code serves with its embedded ugrep) held the
//! agent for 33 of its 60 minutes. Claude Code's Bash tool does not kill a
//! call at its timeout by default: it moves the call to the background
//! (observed on 2.1.280: "Command did not complete within its 120s timeout
//! and was moved to the background"), and the agent then waits on it.
//!
//! The harness knobs, all documented Claude Code env vars and present in the
//! binary on the fleet (2.1.197 on cuphead, 2.1.280 on the Mac):
//! - `CLAUDE_CODE_DISABLE_BACKGROUND_TASKS=1` turns auto-backgrounding (and
//!   `run_in_background`) off, so a call that hits its timeout is killed and
//!   the agent gets the error. Probe on cuphead 2026-10-17 with a 5s default:
//!   `sleep 25` came back as "Command timed out after 5s (exit code 143)",
//!   the agent answered, the whole run took 10s and left no `sleep` behind.
//! - `BASH_DEFAULT_TIMEOUT_MS`: the per-call timeout when the agent passes none.
//! - `BASH_MAX_TIMEOUT_MS`: the longest timeout the agent may ask for (long
//!   builds: cuphead clippy runs 540 to 1000s under load).
//!
//! The watchdog is the backstop for a call that escapes the harness kill: a
//! tool-call shell still alive past the longest allowed timeout is reported
//! once as `kind=agent_tool_call_stalled` and its process subtree is killed,
//! so the tool call fails and the agent continues.

/// Per-call default timeout for headless agent tool calls, seconds. 0 turns
/// the timeout env and the watchdog off.
pub const TOOL_CALL_TIMEOUT_ENV: &str = "CHUMP_DISPATCH_TOOL_CALL_TIMEOUT_SECS";
pub const DEFAULT_TOOL_CALL_TIMEOUT_SECS: u64 = 300;
/// Longest timeout an agent may request for one call (long local builds).
pub const MAX_TOOL_CALL_TIMEOUT_SECS: u64 = 1200;
/// Slack past the longest allowed timeout before the watchdog acts.
const STALL_GRACE_SECS: u64 = 60;
/// Claude Code runs every Bash tool call as
/// `bash -c source <home>/.claude/shell-snapshots/snapshot-... && eval '<cmd>'`;
/// this marks a direct child of the agent as a tool call (MCP servers and
/// other long-lived helpers do not carry it).
const TOOL_CALL_MARKER: &str = "shell-snapshots";

pub fn tool_call_timeout_secs() -> u64 {
    std::env::var(TOOL_CALL_TIMEOUT_ENV)
        .ok()
        .and_then(|s| s.trim().parse().ok())
        .unwrap_or(DEFAULT_TOOL_CALL_TIMEOUT_SECS)
}

/// Env the dispatch sets on a headless `claude -p` child. Empty when the
/// timeout is 0.
pub fn headless_tool_timeout_env(timeout_secs: u64) -> Vec<(&'static str, String)> {
    if timeout_secs == 0 {
        return Vec::new();
    }
    let max = MAX_TOOL_CALL_TIMEOUT_SECS.max(timeout_secs);
    vec![
        ("CLAUDE_CODE_DISABLE_BACKGROUND_TASKS", "1".to_string()),
        ("BASH_DEFAULT_TIMEOUT_MS", (timeout_secs * 1000).to_string()),
        ("BASH_MAX_TIMEOUT_MS", (max * 1000).to_string()),
    ]
}

/// Age at which a tool call has outlived every timeout the harness allows.
pub fn stall_threshold_secs(timeout_secs: u64) -> u64 {
    if timeout_secs == 0 {
        return 0;
    }
    MAX_TOOL_CALL_TIMEOUT_SECS.max(timeout_secs) + STALL_GRACE_SECS
}

#[derive(Debug, Clone, PartialEq)]
pub struct Proc {
    pub pid: u32,
    pub ppid: u32,
    pub age_secs: u64,
    pub args: String,
}

/// A tool call older than the threshold, with every pid in its subtree.
#[derive(Debug, Clone, PartialEq)]
pub struct Stalled {
    pub pid: u32,
    pub age_secs: u64,
    pub cmd: String,
    pub subtree: Vec<u32>,
}

/// Parse `ps -o etime` (`[[dd-]hh:]mm:ss`) to seconds.
pub fn parse_etime(s: &str) -> Option<u64> {
    let s = s.trim();
    let (days, rest) = match s.split_once('-') {
        Some((d, r)) => (d.parse::<u64>().ok()?, r),
        None => (0, s),
    };
    let parts: Vec<u64> = rest
        .split(':')
        .map(|p| p.parse::<u64>().ok())
        .collect::<Option<Vec<_>>>()?;
    let (h, m, sec) = match parts.as_slice() {
        [m, s] => (0, *m, *s),
        [h, m, s] => (*h, *m, *s),
        _ => return None,
    };
    Some(days * 86_400 + h * 3600 + m * 60 + sec)
}

/// Parse `ps -A -o pid=,ppid=,etime=,args=` output.
pub fn parse_ps(out: &str) -> Vec<Proc> {
    out.lines()
        .filter_map(|l| {
            let mut it = l.split_whitespace();
            let pid = it.next()?.parse().ok()?;
            let ppid = it.next()?.parse().ok()?;
            let age_secs = parse_etime(it.next()?)?;
            let args = it.collect::<Vec<_>>().join(" ");
            Some(Proc {
                pid,
                ppid,
                age_secs,
                args,
            })
        })
        .collect()
}

pub fn ps_snapshot() -> Vec<Proc> {
    std::process::Command::new("ps")
        .args(["-A", "-o", "pid=,ppid=,etime=,args="])
        .output()
        .map(|o| parse_ps(&String::from_utf8_lossy(&o.stdout)))
        .unwrap_or_default()
}

fn subtree(procs: &[Proc], top: u32) -> Vec<u32> {
    let mut out = vec![top];
    let mut i = 0;
    while i < out.len() {
        let parent = out[i];
        for p in procs {
            if p.ppid == parent && !out.contains(&p.pid) {
                out.push(p.pid);
            }
        }
        i += 1;
    }
    out
}

/// Tool-call shells (direct children of `root` carrying the Claude Code
/// tool-call marker) older than `threshold_secs`. `cmd` is the longest-lived
/// non-shell process under the call, or the shell itself, truncated.
pub fn find_stalled(procs: &[Proc], root: u32, threshold_secs: u64) -> Vec<Stalled> {
    if threshold_secs == 0 {
        return Vec::new();
    }
    procs
        .iter()
        .filter(|p| p.ppid == root && p.args.contains(TOOL_CALL_MARKER))
        .filter(|p| p.age_secs > threshold_secs)
        .map(|p| {
            let tree = subtree(procs, p.pid);
            let leaf = procs
                .iter()
                .filter(|q| q.pid != p.pid && tree.contains(&q.pid))
                .filter(|q| !q.args.contains(TOOL_CALL_MARKER))
                .max_by_key(|q| q.age_secs)
                .map(|q| q.args.clone())
                .unwrap_or_else(|| p.args.clone());
            Stalled {
                pid: p.pid,
                age_secs: p.age_secs,
                cmd: leaf.chars().take(200).collect(),
                subtree: tree,
            }
        })
        .collect()
}

/// SIGKILL a stalled call's subtree, leaves first, so its shell returns an
/// error to the agent instead of hanging on it.
pub fn kill_subtree(pids: &[u32]) {
    for pid in pids.iter().rev() {
        // SAFETY: plain kill(2) on a pid we just observed under our child.
        unsafe {
            libc::kill(*pid as libc::pid_t, libc::SIGKILL);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn etime_forms() {
        assert_eq!(parse_etime("00:05"), Some(5));
        assert_eq!(parse_etime("33:10"), Some(33 * 60 + 10));
        assert_eq!(parse_etime("01:00:00"), Some(3600));
        assert_eq!(parse_etime("2-01:00:01"), Some(2 * 86_400 + 3601));
        assert_eq!(parse_etime("bogus"), None);
    }

    #[test]
    fn timeout_env_disables_background_and_bounds_calls() {
        let env = headless_tool_timeout_env(300);
        let get = |k: &str| env.iter().find(|(n, _)| *n == k).map(|(_, v)| v.clone());
        assert_eq!(
            get("CLAUDE_CODE_DISABLE_BACKGROUND_TASKS").as_deref(),
            Some("1")
        );
        assert_eq!(get("BASH_DEFAULT_TIMEOUT_MS").as_deref(), Some("300000"));
        assert_eq!(get("BASH_MAX_TIMEOUT_MS").as_deref(), Some("1200000"));
        assert!(headless_tool_timeout_env(0).is_empty());
        assert_eq!(stall_threshold_secs(300), 1260);
        assert_eq!(stall_threshold_secs(0), 0);
    }

    fn p(pid: u32, ppid: u32, age: u64, args: &str) -> Proc {
        Proc {
            pid,
            ppid,
            age_secs: age,
            args: args.to_string(),
        }
    }

    #[test]
    fn flags_only_old_tool_call_shells_under_the_agent() {
        let procs = vec![
            p(10, 1, 4000, "claude -p --dangerously-skip-permissions"),
            // the receipt: a tool-call shell running ugrep for 33 minutes
            p(
                11,
                10,
                1980,
                "/bin/bash -c source /home/u/.claude/shell-snapshots/s.sh && eval 'grep -v /proc/'",
            ),
            p(
                12,
                11,
                1979,
                "ugrep -G --ignore-files --hidden -I -v /proc/",
            ),
            // a young tool call
            p(
                13,
                10,
                20,
                "/bin/bash -c source /home/u/.claude/shell-snapshots/s.sh && eval 'ls'",
            ),
            // a long-lived MCP server is not a tool call
            p(14, 10, 4000, "node mcp-server.js"),
            // not under the agent
            p(15, 1, 9000, "/bin/bash -c source /x/shell-snapshots/s.sh"),
        ];
        let s = find_stalled(&procs, 10, 1260);
        assert_eq!(s.len(), 1);
        assert_eq!(s[0].pid, 11);
        assert!(s[0].cmd.starts_with("ugrep"), "{:?}", s[0]);
        assert_eq!(s[0].subtree, vec![11, 12]);
        assert!(find_stalled(&procs, 10, 0).is_empty());
    }

    #[test]
    fn ps_parse_round_trip() {
        let out = "  10     1    01:06:40 claude -p\n  11    10       33:00 /bin/bash -c x\n";
        let v = parse_ps(out);
        assert_eq!(v.len(), 2);
        assert_eq!(v[0].age_secs, 4000);
        assert_eq!(v[1].ppid, 10);
        assert_eq!(v[1].args, "/bin/bash -c x");
    }
}
