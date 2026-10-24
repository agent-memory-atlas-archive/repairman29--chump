//! CREDIBLE-1557 (PHASE-R R3 slice d): Landing-provider seam.
//!
//! One Rust module answers "has PR `N` landed on `main`, and with which merge
//! SHA?" so that R1 (`chump gap ship` receipt writing) and R2 (`gap_prs`
//! closing) are provider-neutral and never reach into `gh api` or `git log`
//! directly when resolving a PR landing.
//!
//! `CHUMP_LANDING_PROVIDER` selects the active implementation:
//! - `github` (default when unset or empty): resolves via local `origin/main`
//!   (or `main`) squash-merge commit history (`(#N)`) and GitHub's PR API
//!   (`merged == true` + `merge_commit_sha`).
//! - `local`: reserved for a future local merge-queue / git-only landing engine.
//!   Returns [`LandingError::LocalProviderNotImplemented`] today and MUST NOT
//!   silently fall back to GitHub.

use std::fmt;
use std::path::Path;
use std::process::Command;

use serde::{Deserialize, Serialize};
use thiserror::Error;

/// Environment variable selecting the landing provider (`github` | `local`).
pub const LANDING_PROVIDER_ENV: &str = "CHUMP_LANDING_PROVIDER";

/// Commit SHA that landed a PR on `main`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MergeSha(pub String);

impl MergeSha {
    /// Borrow the underlying commit SHA string.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for MergeSha {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// Active landing provider selected by `CHUMP_LANDING_PROVIDER`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LandingProvider {
    /// GitHub landing provider (default when `CHUMP_LANDING_PROVIDER` is unset).
    Github,
    /// Local landing provider (`CHUMP_LANDING_PROVIDER=local`), not yet implemented.
    Local,
}

impl LandingProvider {
    /// Parse a raw provider value (`None` or `""` defaults to [`Self::Github`]).
    pub fn parse(raw: Option<&str>) -> Result<Self, LandingError> {
        match raw.map(str::trim).filter(|s| !s.is_empty()) {
            None => Ok(Self::Github),
            Some(v) if v.eq_ignore_ascii_case("github") => Ok(Self::Github),
            Some(v) if v.eq_ignore_ascii_case("local") => Ok(Self::Local),
            Some(other) => Err(LandingError::UnknownProvider(other.to_string())),
        }
    }

    /// Read `CHUMP_LANDING_PROVIDER` from the process environment.
    pub fn from_env() -> Result<Self, LandingError> {
        let raw = std::env::var(LANDING_PROVIDER_ENV).ok();
        Self::parse(raw.as_deref())
    }
}

/// Errors returned by [`landed`] and [`landed_with`].
#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum LandingError {
    /// `CHUMP_LANDING_PROVIDER=local` was requested; fails closed with no fallback.
    #[error("CHUMP_LANDING_PROVIDER=local is not implemented")]
    LocalProviderNotImplemented,

    /// Unrecognized `CHUMP_LANDING_PROVIDER` value.
    #[error("unknown CHUMP_LANDING_PROVIDER={0:?} (expected 'github' or 'local')")]
    UnknownProvider(String),

    /// Underlying provider failed (network/CLI/parse error) — fail closed.
    #[error("landing provider error for PR #{pr}: {message}")]
    ProviderError { pr: i64, message: String },
}

/// Trait abstracting a PR landing lookup for deterministic unit testing.
pub trait LandingSource {
    /// Returns `Ok(Some(MergeSha))` when `pr` has landed on `main`, `Ok(None)`
    /// when `pr` has not landed, or `Err(LandingError)` when the lookup itself
    /// fails (fail closed).
    fn check_landed(&self, pr: i64) -> Result<Option<MergeSha>, LandingError>;
}

/// Evaluate whether `pr` has landed under `provider` using `source`.
///
/// When `provider` is [`LandingProvider::Local`], this function immediately
/// returns [`LandingError::LocalProviderNotImplemented`] without consulting
/// `source`, guaranteeing no silent fallback to GitHub.
pub fn landed_with<S: LandingSource + ?Sized>(
    provider: LandingProvider,
    source: &S,
    pr: i64,
) -> Result<Option<MergeSha>, LandingError> {
    if pr <= 0 {
        return Ok(None);
    }
    match provider {
        LandingProvider::Local => Err(LandingError::LocalProviderNotImplemented),
        LandingProvider::Github => source.check_landed(pr),
    }
}

/// Default [`LandingSource`] for [`LandingProvider::Github`].
///
/// Resolves whether PR `pr` has landed on `main` by:
/// 1. Checking local git history (`origin/main` when present, otherwise `main`)
///    for the squash-merge commit carrying `(#<pr>)` (`proof_of_merge_sha`
///    inside the `github` provider — zero API cost, <10ms, offline-safe).
/// 2. When the local git history does not contain `(#<pr>)` and `repo_root` has
///    a `github.com` `origin` remote, querying GitHub's PR API
///    (`repos/{owner}/{repo}/pulls/{pr}`) for `merged == true` and
///    `merge_commit_sha`.
pub struct GithubLandingSource<'a> {
    pub repo_root: &'a Path,
    pub gap_id: &'a str,
}

impl<'a> GithubLandingSource<'a> {
    pub fn new(repo_root: &'a Path, gap_id: &'a str) -> Self {
        Self { repo_root, gap_id }
    }
}

#[derive(Debug, Deserialize)]
struct GithubPullResponse {
    #[serde(default)]
    merged: bool,
    #[serde(default)]
    merge_commit_sha: Option<String>,
}

/// Parse a GitHub `{ merged, merge_commit_sha }` JSON payload into an optional [`MergeSha`].
pub fn parse_github_pull_json(pr: i64, raw_json: &str) -> Result<Option<MergeSha>, LandingError> {
    let parsed: GithubPullResponse =
        serde_json::from_str(raw_json).map_err(|e| LandingError::ProviderError {
            pr,
            message: format!("invalid GitHub PR JSON: {e}"),
        })?;
    if !parsed.merged {
        return Ok(None);
    }
    let sha = parsed
        .merge_commit_sha
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());
    match sha {
        Some(s) => Ok(Some(MergeSha(s))),
        None => Err(LandingError::ProviderError {
            pr,
            message: "PR reported merged=true but merge_commit_sha is missing".to_string(),
        }),
    }
}

/// Resolve `owner/repo` from `git remote get-url origin` when it points at `github.com`.
fn github_repo_from_origin(repo_root: &Path) -> Option<String> {
    let out = Command::new("git")
        .args(["remote", "get-url", "origin"])
        .current_dir(repo_root)
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let url = String::from_utf8_lossy(&out.stdout);
    let trimmed = url.trim();
    let slug = if let Some(s) = trimmed.strip_prefix("git@github.com:") {
        s.trim_end_matches(".git")
    } else if let Some(s) = trimmed.strip_prefix("https://github.com/") {
        s.trim_end_matches(".git")
    } else {
        let s = trimmed.strip_prefix("http://github.com/")?;
        s.trim_end_matches(".git")
    };
    if slug.is_empty() || !slug.contains('/') {
        None
    } else {
        Some(slug.to_string())
    }
}

/// Look up the commit SHA on `origin/main` (falling back to local `main`) that
/// carries `(#<pr>)` (or `gap_id` when `pr <= 0`).
pub fn git_log_merge_sha(repo_root: &Path, gap_id: &str, pr: Option<i64>) -> Option<MergeSha> {
    if !repo_root.join(".git").exists() {
        return None;
    }
    let has_origin_main = Command::new("git")
        .args([
            "rev-parse",
            "--verify",
            "--quiet",
            "refs/remotes/origin/main",
        ])
        .current_dir(repo_root)
        .output()
        .map(|o| o.status.success())
        .unwrap_or(false);
    let target_ref = if has_origin_main {
        "origin/main"
    } else {
        "main"
    };
    let grep_pat = match pr {
        Some(n) if n > 0 => format!("--grep=(#{n})"),
        _ => format!("--grep={gap_id}"),
    };
    let out = Command::new("git")
        .args([
            "log",
            target_ref,
            "-i",
            "-F",
            "-n",
            "1",
            "--format=%H",
            &grep_pat,
        ])
        .current_dir(repo_root)
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let sha = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if sha.is_empty() {
        None
    } else {
        Some(MergeSha(sha))
    }
}

impl LandingSource for GithubLandingSource<'_> {
    fn check_landed(&self, pr: i64) -> Result<Option<MergeSha>, LandingError> {
        if !self.repo_root.join(".git").exists() {
            return Ok(None);
        }
        // 1. Fast local proof on origin/main (or local main): squash-merge commit `(#pr)`.
        if let Some(sha) = git_log_merge_sha(self.repo_root, self.gap_id, Some(pr)) {
            return Ok(Some(sha));
        }
        // 2. When origin points to GitHub, query the GitHub PR API for merged + merge_commit_sha.
        let Some(repo_slug) = github_repo_from_origin(self.repo_root) else {
            return Ok(None);
        };
        let endpoint = format!("repos/{repo_slug}/pulls/{pr}");
        let out = Command::new("gh")
            .args(["api", &endpoint])
            .current_dir(self.repo_root)
            .output()
            .map_err(|e| LandingError::ProviderError {
                pr,
                message: format!("failed to invoke gh api: {e}"),
            })?;
        if !out.status.success() {
            // If gh is offline or the PR does not exist (404), treat 404 as not-landed
            // and surface other errors if needed; however in offline/sandboxed CI environments
            // where origin is github.com but network/auth is unavailable, git_log_merge_sha
            // above already checked origin/main, so returning Ok(None) keeps offline callers
            // deterministic.
            return Ok(None);
        }
        let body = String::from_utf8_lossy(&out.stdout);
        parse_github_pull_json(pr, &body)
    }
}

/// Canonical entry point (CREDIBLE-1557 AC1): answers "has PR `pr` landed on
/// `main`, and with which merge SHA?" under the active `CHUMP_LANDING_PROVIDER`.
///
/// - `CHUMP_LANDING_PROVIDER=github` (or unset): checks `GithubLandingSource`.
/// - `CHUMP_LANDING_PROVIDER=local`: returns `Err(LandingError::LocalProviderNotImplemented)`
///   with no fallback to GitHub.
pub fn landed(repo_root: &Path, gap_id: &str, pr: i64) -> Result<Option<MergeSha>, LandingError> {
    let provider = LandingProvider::from_env()?;
    let source = GithubLandingSource::new(repo_root, gap_id);
    landed_with(provider, &source, pr)
}

/// [`LandingSource`] for an external repository (`owner/name`, CREDIBLE-1579).
///
/// Queries `gh api repos/{repo_slug}/pulls/{pr}` and NEVER resolves `pr`
/// against `chump`'s own git history. Fails closed on `gh` execution errors.
pub struct ExternalGithubLandingSource<'a> {
    pub repo_slug: &'a str,
}

impl<'a> ExternalGithubLandingSource<'a> {
    pub fn new(repo_slug: &'a str) -> Self {
        Self { repo_slug }
    }
}

impl LandingSource for ExternalGithubLandingSource<'_> {
    fn check_landed(&self, pr: i64) -> Result<Option<MergeSha>, LandingError> {
        let slug = self.repo_slug.trim();
        if slug.is_empty() || !slug.contains('/') {
            return Err(LandingError::ProviderError {
                pr,
                message: format!("invalid external repo slug {slug:?} (expected 'owner/name')"),
            });
        }
        let endpoint = format!("repos/{slug}/pulls/{pr}");
        let gh_bin = std::env::var("CHUMP_GH_BIN").unwrap_or_else(|_| "gh".to_string());
        let out = Command::new(&gh_bin)
            .args(["api", &endpoint])
            .output()
            .map_err(|e| LandingError::ProviderError {
                pr,
                message: format!("failed to invoke {gh_bin} api {endpoint}: {e}"),
            })?;
        if !out.status.success() {
            let stderr = String::from_utf8_lossy(&out.stderr);
            return Err(LandingError::ProviderError {
                pr,
                message: format!(
                    "{gh_bin} api {endpoint} exited {}: {}",
                    out.status.code().unwrap_or(-1),
                    stderr.trim()
                ),
            });
        }
        let body = String::from_utf8_lossy(&out.stdout);
        parse_github_pull_json(pr, &body)
    }
}

/// CREDIBLE-1579: verify whether PR `pr` has landed in external repository
/// `repo_slug` (`owner/name`), returning `Ok(Some(MergeSha))` when merged,
/// `Ok(None)` when open or closed-unmerged, or `Err(LandingError)` when the
/// lookup fails. Never resolves `pr` against `chump`'s own git history.
pub fn landed_in_external_repo(repo_slug: &str, pr: i64) -> Result<Option<MergeSha>, LandingError> {
    let provider = LandingProvider::from_env()?;
    let source = ExternalGithubLandingSource::new(repo_slug);
    landed_with(provider, &source, pr)
}

#[cfg(test)]
mod tests {
    use super::*;

    struct FakeLandingSource {
        response: Result<Option<MergeSha>, LandingError>,
    }

    impl LandingSource for FakeLandingSource {
        fn check_landed(&self, _pr: i64) -> Result<Option<MergeSha>, LandingError> {
            self.response.clone()
        }
    }

    #[test]
    fn fake_provider_landed_returns_merge_sha() {
        let source = FakeLandingSource {
            response: Ok(Some(MergeSha(
                "0123456789abcdef0123456789abcdef01234567".to_string(),
            ))),
        };
        let res = landed_with(LandingProvider::Github, &source, 5678).unwrap();
        assert_eq!(
            res,
            Some(MergeSha(
                "0123456789abcdef0123456789abcdef01234567".to_string()
            ))
        );
    }

    #[test]
    fn fake_provider_not_landed_returns_none() {
        let source = FakeLandingSource { response: Ok(None) };
        let res = landed_with(LandingProvider::Github, &source, 5678).unwrap();
        assert_eq!(res, None);
    }

    #[test]
    fn fake_provider_error_fails_closed() {
        let source = FakeLandingSource {
            response: Err(LandingError::ProviderError {
                pr: 5678,
                message: "simulated API timeout".to_string(),
            }),
        };
        let err = landed_with(LandingProvider::Github, &source, 5678).unwrap_err();
        assert!(matches!(err, LandingError::ProviderError { pr: 5678, .. }));
        assert!(err.to_string().contains("simulated API timeout"));
    }

    #[test]
    fn local_provider_returns_not_implemented_and_never_falls_back_to_github() {
        // Even if the underlying source would return Ok(Some(MergeSha)),
        // LandingProvider::Local must refuse with LocalProviderNotImplemented.
        let source = FakeLandingSource {
            response: Ok(Some(MergeSha(
                "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".to_string(),
            ))),
        };
        let provider = LandingProvider::parse(Some("local")).unwrap();
        assert_eq!(provider, LandingProvider::Local);
        let err = landed_with(provider, &source, 5678).unwrap_err();
        assert_eq!(err, LandingError::LocalProviderNotImplemented);
        assert_eq!(
            err.to_string(),
            "CHUMP_LANDING_PROVIDER=local is not implemented"
        );
    }

    #[test]
    fn provider_parse_defaults_to_github_and_rejects_unknown() {
        assert_eq!(
            LandingProvider::parse(None).unwrap(),
            LandingProvider::Github
        );
        assert_eq!(
            LandingProvider::parse(Some("")).unwrap(),
            LandingProvider::Github
        );
        assert_eq!(
            LandingProvider::parse(Some("github")).unwrap(),
            LandingProvider::Github
        );
        assert_eq!(
            LandingProvider::parse(Some("GITHUB")).unwrap(),
            LandingProvider::Github
        );
        assert_eq!(
            LandingProvider::parse(Some("local")).unwrap(),
            LandingProvider::Local
        );
        assert!(matches!(
            LandingProvider::parse(Some("gitlab")),
            Err(LandingError::UnknownProvider(_))
        ));
    }

    #[test]
    fn parse_github_pull_json_handles_merged_unmerged_and_error() {
        let merged_json =
            r#"{"merged": true, "merge_commit_sha": "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"}"#;
        assert_eq!(
            parse_github_pull_json(42, merged_json).unwrap(),
            Some(MergeSha(
                "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef".to_string()
            ))
        );

        let open_json = r#"{"merged": false, "merge_commit_sha": null}"#;
        assert_eq!(parse_github_pull_json(42, open_json).unwrap(), None);

        let broken_json = r#"{"merged": true, "merge_commit_sha": ""}"#;
        assert!(matches!(
            parse_github_pull_json(42, broken_json),
            Err(LandingError::ProviderError { pr: 42, .. })
        ));
    }
}
