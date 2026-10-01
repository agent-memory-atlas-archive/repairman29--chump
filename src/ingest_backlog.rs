//! `chump ingest <repo-path> --import-backlog` — MISSION-055.
//!
//! Reads a repo's DEFINED backlog — `.beast-mode-tasks.json`, a `beads`
//! JSONL store, or a plain `TODO`/`TODO.md` checklist — and creates one
//! fleet gap per item via `chump gap reserve`, tagged
//! `external_repo:<repo-tag>` (MISSION-041 routing key). Idempotent: each
//! item gets a stable `[ingest:<repo-tag>:<key>]` marker appended to its
//! gap title, and a re-run skips any key that marker already proves exists.
//!
//! Deliberately narrow scope: reads the FIRST backlog source found, in
//! priority order beast-mode-tasks.json > beads > TODO. Doesn't attempt to
//! merge multiple sources or infer priority/effort from the source file —
//! every imported gap lands as P2/xs, permissionless per MISSION-045.

use std::collections::HashSet;
use std::path::Path;

pub struct BacklogItem {
    pub key: String,
    pub title: String,
}

pub struct ImportReport {
    pub source: String,
    pub items_found: usize,
    pub gaps_created: usize,
    pub gaps_skipped_existing: usize,
    pub created_ids: Vec<String>,
}

/// Locate the first backlog source present under `repo_path` and parse it.
/// Returns `(source_label, items)` or `None` if no recognized backlog file
/// exists.
pub fn discover_backlog(repo_path: &Path) -> Option<(String, Vec<BacklogItem>)> {
    let beast_mode = repo_path.join(".beast-mode-tasks.json");
    if beast_mode.is_file() {
        let items = parse_beast_mode_tasks(&beast_mode);
        return Some((".beast-mode-tasks.json".to_string(), items));
    }

    for beads_rel in [".beads/issues.jsonl", "beads.jsonl", ".beads.jsonl"] {
        let beads_path = repo_path.join(beads_rel);
        if beads_path.is_file() {
            let items = parse_beads(&beads_path);
            return Some((beads_rel.to_string(), items));
        }
    }

    for todo_rel in ["TODO.md", "TODO"] {
        let todo_path = repo_path.join(todo_rel);
        if todo_path.is_file() {
            let items = parse_todo(&todo_path);
            return Some((todo_rel.to_string(), items));
        }
    }

    None
}

fn parse_beast_mode_tasks(path: &Path) -> Vec<BacklogItem> {
    let Ok(raw) = std::fs::read_to_string(path) else {
        return Vec::new();
    };
    let Ok(value) = serde_json::from_str::<serde_json::Value>(&raw) else {
        return Vec::new();
    };
    let array = value
        .as_array()
        .cloned()
        .or_else(|| value.get("tasks").and_then(|v| v.as_array()).cloned())
        .unwrap_or_default();

    array
        .iter()
        .enumerate()
        .filter_map(|(idx, item)| {
            let title = item
                .get("title")
                .or_else(|| item.get("task"))
                .or_else(|| item.get("name"))
                .or_else(|| item.get("description"))
                .and_then(|v| v.as_str())
                .map(str::trim)
                .filter(|s| !s.is_empty())?;
            let key = item
                .get("id")
                .or_else(|| item.get("task_id"))
                .and_then(|v| {
                    v.as_str()
                        .map(str::to_string)
                        .or_else(|| v.as_i64().map(|n| n.to_string()))
                })
                .unwrap_or_else(|| format!("idx{idx}"));
            Some(BacklogItem {
                key,
                title: title.to_string(),
            })
        })
        .collect()
}

fn parse_beads(path: &Path) -> Vec<BacklogItem> {
    let Ok(raw) = std::fs::read_to_string(path) else {
        return Vec::new();
    };
    raw.lines()
        .enumerate()
        .filter_map(|(idx, line)| {
            let line = line.trim();
            if line.is_empty() {
                return None;
            }
            let value: serde_json::Value = serde_json::from_str(line).ok()?;
            let title = value
                .get("title")
                .or_else(|| value.get("summary"))
                .or_else(|| value.get("text"))
                .and_then(|v| v.as_str())
                .map(str::trim)
                .filter(|s| !s.is_empty())?;
            let key = value
                .get("id")
                .and_then(|v| {
                    v.as_str()
                        .map(str::to_string)
                        .or_else(|| v.as_i64().map(|n| n.to_string()))
                })
                .unwrap_or_else(|| format!("line{idx}"));
            Some(BacklogItem {
                key,
                title: title.to_string(),
            })
        })
        .collect()
}

fn parse_todo(path: &Path) -> Vec<BacklogItem> {
    let Ok(raw) = std::fs::read_to_string(path) else {
        return Vec::new();
    };
    raw.lines()
        .enumerate()
        .filter_map(|(idx, line)| {
            let trimmed = line.trim();
            let text = trimmed
                .strip_prefix("- [ ]")
                .or_else(|| trimmed.strip_prefix("* [ ]"))
                .or_else(|| trimmed.strip_prefix("- "))
                .or_else(|| trimmed.strip_prefix("* "))
                .or_else(|| trimmed.strip_prefix("TODO:"))
                .map(str::trim)
                .filter(|s| !s.is_empty())?;
            Some(BacklogItem {
                key: format!("line{idx}"),
                title: text.to_string(),
            })
        })
        .collect()
}

/// Derive a stable repo tag for `external_repo:<tag>` — `owner/repo` from
/// the `origin` remote when available, else the directory basename.
pub fn derive_repo_tag(repo_path: &Path) -> String {
    let output = std::process::Command::new("git")
        .args([
            "-C",
            &repo_path.to_string_lossy(),
            "remote",
            "get-url",
            "origin",
        ])
        .output();
    if let Ok(out) = output {
        if out.status.success() {
            let url = String::from_utf8_lossy(&out.stdout).trim().to_string();
            if let Some(tag) = parse_owner_repo(&url) {
                return tag;
            }
        }
    }
    repo_path
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "unknown-repo".to_string())
}

fn parse_owner_repo(url: &str) -> Option<String> {
    let trimmed = url.trim().trim_end_matches(".git");
    let tail = trimmed
        .rsplit_once("github.com:")
        .or_else(|| trimmed.rsplit_once("github.com/"))
        .map(|(_, t)| t)?;
    let parts: Vec<&str> = tail.split('/').filter(|s| !s.is_empty()).collect();
    if parts.len() >= 2 {
        Some(format!(
            "{}/{}",
            parts[parts.len() - 2],
            parts[parts.len() - 1]
        ))
    } else {
        None
    }
}

fn ingest_marker(repo_tag: &str, key: &str) -> String {
    format!("[ingest:{repo_tag}:{key}]")
}

/// Query the fleet's own `.chump/state.db` (chump_repo_root, NOT the target
/// repo) for gap titles already carrying an `[ingest:<repo_tag>:*]` marker,
/// so re-running the import is a no-op for items already filed.
fn existing_markers(chump_repo_root: &Path, repo_tag: &str) -> HashSet<String> {
    let prefix = format!("[ingest:{repo_tag}:");
    let mut found = HashSet::new();
    if let Ok(store) = chump_gap_store::GapStore::open(chump_repo_root) {
        if let Ok(rows) = store.list(None) {
            for row in rows {
                if let Some(start) = row.title.find(&prefix) {
                    if let Some(end_rel) = row.title[start..].find(']') {
                        let marker = &row.title[start..start + end_rel + 1];
                        found.insert(marker.to_string());
                    }
                }
            }
        }
    }
    found
}

/// Reserve one gap for `item`, tagged `external_repo:<repo_tag>`, via the
/// `chump gap reserve` CLI (reuses its gates/ID-allocation/dedup telemetry
/// rather than re-implementing them — same rationale as
/// `commands::bootstrap::reserve_umbrella_gap`).
fn reserve_gap(domain: &str, title: &str, repo_tag: &str) -> Option<String> {
    let output = std::process::Command::new("chump")
        .args([
            "gap",
            "reserve",
            "--domain",
            domain,
            "--title",
            title,
            "--external-repo",
            repo_tag,
            "--priority",
            "P2",
            "--effort",
            "xs",
            "--force",
            "--quiet",
            "--json",
        ])
        .output()
        .ok()?;
    if !output.status.success() {
        eprintln!(
            "chump ingest: gap reserve failed for \"{title}\": {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
        return None;
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    let value: serde_json::Value = serde_json::from_str(stdout.trim()).ok()?;
    value.get("id").and_then(|v| v.as_str()).map(str::to_string)
}

const MAX_TITLE_LEN: usize = 160;

/// Entry point for `chump ingest <repo-path> --import-backlog`.
pub fn run_import(repo_path: &Path, domain: &str) -> Result<ImportReport, String> {
    let (source, items) = match discover_backlog(repo_path) {
        Some(found) => found,
        None => {
            return Err(
                "no defined backlog found (looked for .beast-mode-tasks.json, \
                 .beads/issues.jsonl, TODO.md, TODO)"
                    .to_string(),
            )
        }
    };

    let repo_tag = derive_repo_tag(repo_path);
    let chump_repo_root = crate::repo_path::repo_root();
    let already_imported = existing_markers(&chump_repo_root, &repo_tag);

    let mut created_ids = Vec::new();
    let mut skipped = 0usize;

    for item in &items {
        let marker = ingest_marker(&repo_tag, &item.key);
        if already_imported.contains(&marker) {
            skipped += 1;
            continue;
        }
        let mut title = item.title.clone();
        if title.len() > MAX_TITLE_LEN {
            title.truncate(MAX_TITLE_LEN);
        }
        let full_title = format!("{title} {marker}");
        match reserve_gap(domain, &full_title, &repo_tag) {
            Some(id) => created_ids.push(id),
            None => {
                eprintln!(
                    "chump ingest: skipping item key={} (reserve failed)",
                    item.key
                );
            }
        }
    }

    Ok(ImportReport {
        source,
        items_found: items.len(),
        gaps_created: created_ids.len(),
        gaps_skipped_existing: skipped,
        created_ids,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::path::PathBuf;

    fn write_file(dir: &Path, rel: &str, content: &str) -> PathBuf {
        let path = dir.join(rel);
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).unwrap();
        }
        let mut f = std::fs::File::create(&path).unwrap();
        f.write_all(content.as_bytes()).unwrap();
        path
    }

    #[test]
    fn parses_beast_mode_tasks_array() {
        let dir = tempfile::tempdir().unwrap();
        write_file(
            dir.path(),
            ".beast-mode-tasks.json",
            r#"[{"id":"t1","title":"Add retries"},{"id":"t2","title":"Fix flake"}]"#,
        );
        let (source, items) = discover_backlog(dir.path()).unwrap();
        assert_eq!(source, ".beast-mode-tasks.json");
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].key, "t1");
        assert_eq!(items[0].title, "Add retries");
    }

    #[test]
    fn parses_beast_mode_tasks_wrapped_object() {
        let dir = tempfile::tempdir().unwrap();
        write_file(
            dir.path(),
            ".beast-mode-tasks.json",
            r#"{"tasks":[{"task_id":5,"task":"Ship it"}]}"#,
        );
        let (_source, items) = discover_backlog(dir.path()).unwrap();
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].key, "5");
        assert_eq!(items[0].title, "Ship it");
    }

    #[test]
    fn parses_beads_jsonl() {
        let dir = tempfile::tempdir().unwrap();
        write_file(
            dir.path(),
            ".beads/issues.jsonl",
            "{\"id\":\"b-1\",\"title\":\"Investigate crash\"}\n{\"id\":\"b-2\",\"summary\":\"Add docs\"}\n",
        );
        let (source, items) = discover_backlog(dir.path()).unwrap();
        assert_eq!(source, ".beads/issues.jsonl");
        assert_eq!(items.len(), 2);
        assert_eq!(items[1].title, "Add docs");
    }

    #[test]
    fn parses_todo_checklist() {
        let dir = tempfile::tempdir().unwrap();
        write_file(
            dir.path(),
            "TODO.md",
            "# TODO\n- [ ] Write tests\n- [ ] Ship feature\nnot a task line\n",
        );
        let (source, items) = discover_backlog(dir.path()).unwrap();
        assert_eq!(source, "TODO.md");
        assert_eq!(items.len(), 2);
        assert_eq!(items[0].title, "Write tests");
    }

    #[test]
    fn prefers_beast_mode_over_beads_and_todo() {
        let dir = tempfile::tempdir().unwrap();
        write_file(
            dir.path(),
            ".beast-mode-tasks.json",
            r#"[{"id":"1","title":"A"}]"#,
        );
        write_file(
            dir.path(),
            ".beads/issues.jsonl",
            "{\"id\":\"2\",\"title\":\"B\"}\n",
        );
        write_file(dir.path(), "TODO.md", "- [ ] C\n");
        let (source, _items) = discover_backlog(dir.path()).unwrap();
        assert_eq!(source, ".beast-mode-tasks.json");
    }

    #[test]
    fn no_backlog_found_returns_none() {
        let dir = tempfile::tempdir().unwrap();
        assert!(discover_backlog(dir.path()).is_none());
    }

    #[test]
    fn ingest_marker_format() {
        assert_eq!(ingest_marker("owner/repo", "t1"), "[ingest:owner/repo:t1]");
    }

    #[test]
    fn parse_owner_repo_from_https_url() {
        assert_eq!(
            parse_owner_repo("https://github.com/foo/bar.git"),
            Some("foo/bar".to_string())
        );
    }

    #[test]
    fn parse_owner_repo_from_ssh_url() {
        assert_eq!(
            parse_owner_repo("git@github.com:foo/bar.git"),
            Some("foo/bar".to_string())
        );
    }

    #[test]
    fn parse_owner_repo_non_github_returns_none() {
        assert_eq!(parse_owner_repo("https://example.com/foo/bar.git"), None);
    }
}
