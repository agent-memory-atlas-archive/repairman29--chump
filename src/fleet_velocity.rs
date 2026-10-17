//! INFRA-566: Fleet velocity dashboard.
//!
//! `chump fleet-velocity` — ships/hour over last 1h/6h/24h from
//! `session_end outcome=shipped` events in ambient.jsonl, plus a
//! forecast of how long until the open gap queue empties at the
//! current rate. Companion to `chump fleet-status` (INFRA-494).

use std::path::Path;

#[derive(Debug, Default)]
pub struct VelocitySnapshot {
    pub shipped_1h: u64,
    pub shipped_6h: u64,
    pub shipped_24h: u64,
    /// Open gaps remaining in state.db (for forecast denominator).
    pub open_gaps: u64,
}

impl VelocitySnapshot {
    pub fn rate_per_hour_1h(&self) -> f64 {
        self.shipped_1h as f64
    }

    pub fn rate_per_hour_6h(&self) -> f64 {
        self.shipped_6h as f64 / 6.0
    }

    pub fn rate_per_hour_24h(&self) -> f64 {
        self.shipped_24h as f64 / 24.0
    }

    /// Forecast hours to empty the queue using the most recent
    /// non-zero window (1h > 6h > 24h).
    pub fn forecast_hours(&self) -> Option<f64> {
        let rate = if self.rate_per_hour_1h() > 0.0 {
            self.rate_per_hour_1h()
        } else if self.rate_per_hour_6h() > 0.0 {
            self.rate_per_hour_6h()
        } else if self.rate_per_hour_24h() > 0.0 {
            self.rate_per_hour_24h()
        } else {
            return None;
        };
        Some(self.open_gaps as f64 / rate)
    }

    pub fn render_text(&self) -> String {
        let mut out = String::new();
        out.push_str("═══ Fleet Velocity ═══\n");
        out.push_str(&format!(
            "  Ships/hour  1h:  {:.2}  ({} shipped)\n",
            self.rate_per_hour_1h(),
            self.shipped_1h
        ));
        out.push_str(&format!(
            "  Ships/hour  6h:  {:.2}  ({} shipped)\n",
            self.rate_per_hour_6h(),
            self.shipped_6h
        ));
        out.push_str(&format!(
            "  Ships/hour 24h:  {:.2}  ({} shipped)\n",
            self.rate_per_hour_24h(),
            self.shipped_24h
        ));
        out.push('\n');
        out.push_str(&format!("  Open gaps:       {}\n", self.open_gaps));
        match self.forecast_hours() {
            Some(h) if h < 1.0 => {
                out.push_str(
                    "  Forecast:        queue clears in <1h — consider filing more gaps\n",
                );
            }
            Some(h) if h > 999.0 => {
                out.push_str("  Forecast:        queue clears in >999h (effectively never at current rate)\n");
            }
            Some(h) => {
                out.push_str(&format!(
                    "  Forecast:        queue empty in ~{:.0}h at current rate\n",
                    h
                ));
                if h < 4.0 {
                    out.push_str("  ⚠  Low runway — consider filing more gaps soon\n");
                }
            }
            None => {
                out.push_str(
                    "  Forecast:        no recent ships — fleet idle or all gaps claimed\n",
                );
            }
        }
        out.push_str("\n  Drill down: chump fleet-status\n");
        out
    }
}

/// Build a velocity snapshot for the given repo root.
pub fn snapshot(repo_root: &Path) -> VelocitySnapshot {
    let mut snap = VelocitySnapshot::default();

    // Count shipped events in each window from ambient.jsonl.
    let ambient = repo_root.join(".chump-locks/ambient.jsonl");
    let contents = std::fs::read_to_string(&ambient).unwrap_or_default();
    let now = current_unix();
    let cutoff_1h = now.saturating_sub(3600);
    let cutoff_6h = now.saturating_sub(6 * 3600);
    let cutoff_24h = now.saturating_sub(24 * 3600);

    for line in contents.lines() {
        if !line.contains(r#""kind":"session_end""#) {
            continue;
        }
        if extract_field(line, "outcome").as_deref() != Some("shipped") {
            continue;
        }
        let ts = extract_field(line, "ts")
            .and_then(|t| parse_iso8601_to_unix(&t))
            .unwrap_or(0);
        if ts >= cutoff_24h {
            snap.shipped_24h += 1;
        }
        if ts >= cutoff_6h {
            snap.shipped_6h += 1;
        }
        if ts >= cutoff_1h {
            snap.shipped_1h += 1;
        }
    }

    // Open gap count from state.db.
    let db_path = chump_gap_store::store_path::state_db_path(repo_root); // INFRA-8190
    if db_path.exists() {
        if let Ok(conn) = rusqlite::Connection::open_with_flags(
            &db_path,
            rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
        ) {
            let count: Option<u64> = conn
                .query_row("SELECT COUNT(*) FROM gaps WHERE status='open'", [], |r| {
                    r.get(0)
                })
                .ok();
            snap.open_gaps = count.unwrap_or(0);
        }
    }

    snap
}

// ── Helpers (same approach as fleet_status.rs) ────────────────────────────

fn current_unix() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn parse_iso8601_to_unix(s: &str) -> Option<u64> {
    let out = std::process::Command::new("date")
        .args(["-u", "-j", "-f", "%Y-%m-%dT%H:%M:%SZ", s, "+%s"])
        .output()
        .ok()?;
    if out.status.success() {
        return String::from_utf8_lossy(&out.stdout).trim().parse().ok();
    }
    let out2 = std::process::Command::new("date")
        .args(["-u", "-d", s, "+%s"])
        .output()
        .ok()?;
    if !out2.status.success() {
        return None;
    }
    String::from_utf8_lossy(&out2.stdout).trim().parse().ok()
}

fn extract_field(line: &str, field: &str) -> Option<String> {
    let needle = format!(r#""{}":""#, field);
    let start = line.find(&needle)? + needle.len();
    let rest = &line[start..];
    let mut out = String::new();
    let mut chars = rest.chars();
    while let Some(c) = chars.next() {
        match c {
            '"' => return Some(out),
            '\\' => match chars.next()? {
                'n' => out.push('\n'),
                't' => out.push('\t'),
                'r' => out.push('\r'),
                '\\' => out.push('\\'),
                '"' => out.push('"'),
                'u' => {
                    for _ in 0..4 {
                        chars.next()?;
                    }
                }
                other => out.push(other),
            },
            c => out.push(c),
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tempdir() -> std::path::PathBuf {
        let mut p = std::env::temp_dir();
        p.push(format!(
            "chump-infra566-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&p).unwrap();
        p
    }

    fn now_iso() -> String {
        std::process::Command::new("date")
            .args(["-u", "+%Y-%m-%dT%H:%M:%SZ"])
            .output()
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
            .unwrap_or_else(|_| "2026-05-06T12:00:00Z".to_string())
    }

    #[test]
    fn infra566_empty_snapshot() {
        let tmp = tempdir();
        let snap = snapshot(&tmp);
        assert_eq!(snap.shipped_1h, 0);
        assert_eq!(snap.shipped_6h, 0);
        assert_eq!(snap.shipped_24h, 0);
        assert_eq!(snap.open_gaps, 0);
        assert!(snap.forecast_hours().is_none());
        let text = snap.render_text();
        assert!(text.contains("fleet idle"), "got: {}", text);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra566_counts_shipped_windows() {
        let tmp = tempdir();
        std::fs::create_dir_all(tmp.join(".chump-locks")).unwrap();
        let ts = now_iso();
        let lines = [
            format!(
                r#"{{"kind":"session_end","ts":"{}","session_id":"sA","gap_id":"INFRA-1","outcome":"shipped"}}"#,
                ts
            ),
            format!(
                r#"{{"kind":"session_end","ts":"{}","session_id":"sB","gap_id":"INFRA-2","outcome":"abandoned"}}"#,
                ts
            ),
            format!(
                r#"{{"kind":"session_end","ts":"{}","session_id":"sC","gap_id":"INFRA-3","outcome":"shipped"}}"#,
                ts
            ),
        ];
        std::fs::write(
            tmp.join(".chump-locks/ambient.jsonl"),
            lines.join("\n") + "\n",
        )
        .unwrap();
        let snap = snapshot(&tmp);
        assert_eq!(snap.shipped_1h, 2, "expected 2 shipped in 1h");
        assert_eq!(snap.shipped_6h, 2);
        assert_eq!(snap.shipped_24h, 2);
        let text = snap.render_text();
        assert!(text.contains("Ships/hour  1h:  2.00"), "got: {}", text);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn infra566_forecast_low_runway_warning() {
        let snap = VelocitySnapshot {
            shipped_1h: 4,
            shipped_6h: 12,
            shipped_24h: 20,
            open_gaps: 8,
        };
        // Rate from 1h = 4/h, 8 gaps → 2h forecast → low runway warning.
        let h = snap.forecast_hours().unwrap();
        assert!((h - 2.0).abs() < 0.01, "expected ~2h, got {}", h);
        let text = snap.render_text();
        assert!(text.contains("Low runway"), "got: {}", text);
    }

    #[test]
    fn infra566_render_no_ships_message() {
        let snap = VelocitySnapshot {
            shipped_1h: 0,
            shipped_6h: 0,
            shipped_24h: 0,
            open_gaps: 5,
        };
        let text = snap.render_text();
        assert!(text.contains("fleet idle"), "got: {}", text);
    }
}
