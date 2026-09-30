//! Dual-mode authentication: API-key (ANTHROPIC_API_KEY) and subscription OAUTH
//! (CLAUDE_CODE_OAUTH_TOKEN). Resolves which credential to use, handles per-spawn
//! re-evaluation, and emits fleet_auth_fallback when one mode fails.
//!
//! # Precedence
//! Controlled by `CHUMP_AUTH_MODE=auto|api-key|oauth` (default `auto`).
//! In `auto` mode: prefer a non-empty CLAUDE_CODE_OAUTH_TOKEN (subscription
//! OAUTH is cost-primary), falling back to ANTHROPIC_API_KEY as the
//! non-expiring floor when OAUTH is absent (RESILIENT-057).
//!
//! # Sources checked (in priority order)
//! 1. Environment variables (ANTHROPIC_API_KEY, CLAUDE_CODE_OAUTH_TOKEN)
//! 2. OAUTH refresh file at CHUMP_OAUTH_TOKEN_FILE (written by control.sh every 5 min)
//! 3. ~/.chump/config.toml [api] section (anthropic_api_key / claude_code_oauth_token)

use std::path::{Path, PathBuf};

// ── Types ──────────────────────────────────────────────────────────────────

/// Which auth mode the operator wants.
#[derive(Debug, Clone, PartialEq)]
pub enum AuthMode {
    /// Prefer OAUTH when present and non-empty (cost-primary); fall back to
    /// ANTHROPIC_API_KEY as the non-expiring floor.
    Auto,
    /// Always use ANTHROPIC_API_KEY; error if absent.
    ApiKey,
    /// Always use CLAUDE_CODE_OAUTH_TOKEN (subscription); error if absent.
    OAuth,
}

impl AuthMode {
    fn from_env() -> Self {
        match std::env::var("CHUMP_AUTH_MODE")
            .unwrap_or_default()
            .to_ascii_lowercase()
            .trim()
            .to_string()
            .as_str()
        {
            "api-key" | "api_key" | "apikey" => AuthMode::ApiKey,
            "oauth" => AuthMode::OAuth,
            _ => AuthMode::Auto,
        }
    }
}

/// Raw credentials loaded from all sources.
#[derive(Debug, Clone, Default)]
pub struct AuthCredentials {
    /// Value of ANTHROPIC_API_KEY (env, then config.toml).
    pub api_key: String,
    /// Value of CLAUDE_CODE_OAUTH_TOKEN (env, refresh file, then config.toml).
    pub oauth_token: String,
}

impl AuthCredentials {
    pub fn has_api_key(&self) -> bool {
        !self.api_key.trim().is_empty()
    }

    pub fn has_oauth(&self) -> bool {
        !self.oauth_token.trim().is_empty()
    }
}

/// The resolved auth state for one spawn / re-evaluation cycle.
#[derive(Debug, Clone)]
pub struct ActiveAuth {
    /// Which mode is currently active.
    pub mode: ActiveMode,
    /// The raw credentials that were loaded (both may be set; `mode` says which to use).
    pub creds: AuthCredentials,
}

#[derive(Debug, Clone, PartialEq)]
pub enum ActiveMode {
    ApiKey,
    OAuth,
    /// Neither mode has credentials — auth will fail.
    None,
}

impl ActiveAuth {
    /// Env var pairs to inject into `claude -p` spawns.
    /// Returns `(key, value)` pairs; callers set them in the child environment.
    pub fn env_pairs(&self) -> Vec<(String, String)> {
        match self.mode {
            ActiveMode::ApiKey => vec![
                ("ANTHROPIC_API_KEY".into(), self.creds.api_key.clone()),
                ("CLAUDE_CODE_OAUTH_TOKEN".into(), String::new()),
            ],
            ActiveMode::OAuth => vec![
                (
                    "CLAUDE_CODE_OAUTH_TOKEN".into(),
                    self.creds.oauth_token.clone(),
                ),
                ("ANTHROPIC_API_KEY".into(), String::new()),
            ],
            ActiveMode::None => vec![],
        }
    }

    /// Returns the alternate `ActiveAuth` to try after a 401, or `None` if no fallback.
    /// Also emits a `fleet_auth_fallback` event to ambient.jsonl.
    pub fn on_auth_failure(&self, ambient_path: Option<&Path>) -> Option<ActiveAuth> {
        let fallback = match self.mode {
            ActiveMode::ApiKey if self.creds.has_oauth() => Some(ActiveAuth {
                mode: ActiveMode::OAuth,
                creds: self.creds.clone(),
            }),
            ActiveMode::OAuth if self.creds.has_api_key() => Some(ActiveAuth {
                mode: ActiveMode::ApiKey,
                creds: self.creds.clone(),
            }),
            _ => None,
        };

        if let Some(ref fb) = fallback {
            let failed = format!("{:?}", self.mode).to_lowercase();
            let next = format!("{:?}", fb.mode).to_lowercase();
            let ts = chrono_ts();
            let event = format!(
                "{{\"ts\":\"{ts}\",\"kind\":\"fleet_auth_fallback\",\"failed_mode\":\"{failed}\",\"fallback_mode\":\"{next}\"}}\n"
            );
            emit_ambient(ambient_path, &event);
        }

        fallback
    }

    pub fn is_none(&self) -> bool {
        self.mode == ActiveMode::None
    }

    /// Fail-open wrapper around [`on_auth_failure`](Self::on_auth_failure):
    /// only actually falls back when `err` classifies as
    /// [`AuthFailureKind::Unauthorized`]. Network/timeout/rate-limit errors
    /// classify as `Transient` and return `None` (no fallback, no event) —
    /// RESILIENT-057 AC4: fail-open, don't burn a working credential's
    /// standing over a blip on the other one.
    pub fn on_auth_failure_classified(
        &self,
        err: &str,
        ambient_path: Option<&Path>,
    ) -> Option<ActiveAuth> {
        match AuthFailureKind::classify(err) {
            AuthFailureKind::Unauthorized => self.on_auth_failure(ambient_path),
            AuthFailureKind::Transient => None,
        }
    }
}

/// Classification of an auth-call failure, used to decide whether a
/// fallback to the other credential is warranted (RESILIENT-057).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AuthFailureKind {
    /// A real auth rejection (401/403, "invalid api key", expired token).
    /// Warrants falling back to the other credential.
    Unauthorized,
    /// Network, timeout, rate-limit, or transient server error. Must NOT
    /// trigger a fallback — the current credential may still be good.
    Transient,
}

impl AuthFailureKind {
    /// Classify a raw error/status string from a failed spawn or API call.
    /// Ambiguous/unrecognized errors classify as `Transient` (fail-open):
    /// AC4 requires the burden of proof for "this credential is dead" to
    /// be on unambiguous auth-rejection signals.
    pub fn classify(err: &str) -> Self {
        let lower = err.to_ascii_lowercase();
        let is_transient = lower.contains("timeout")
            || lower.contains("timed out")
            || lower.contains("rate limit")
            || lower.contains("rate_limit")
            || lower.contains("429")
            || lower.contains("connection reset")
            || lower.contains("connection refused")
            || lower.contains("network")
            || lower.contains("temporarily unavailable")
            || lower.contains("502")
            || lower.contains("503")
            || lower.contains("504")
            || lower.contains("overloaded");
        if is_transient {
            return AuthFailureKind::Transient;
        }
        let is_unauthorized = lower.contains("401")
            || lower.contains("403")
            || lower.contains("unauthorized")
            || lower.contains("invalid api key")
            || lower.contains("invalid x-api-key")
            || lower.contains("invalid bearer")
            || lower.contains("authentication_error")
            || lower.contains("expired token")
            || lower.contains("oauth token expired")
            || lower.contains("permission_error");
        if is_unauthorized {
            AuthFailureKind::Unauthorized
        } else {
            AuthFailureKind::Transient
        }
    }
}

// ── Validate-before-use (RESILIENT-057) ─────────────────────────────────────
//
// A tiny cached "is this credential known-dead?" store, keyed by
// (mode, credential fingerprint) so a rotated/refreshed credential is
// treated as unvalidated again. Written by `record_validation_result` after
// a real spawn observes success/failure; read by `resolve_for_spawn` so the
// NEXT spawn can switch credentials proactively instead of paying the
// latency (and, at fleet scale, the AUTH_DEAD storm) of every worker
// re-discovering the same dead credential independently.

/// How long a cached validation result stays authoritative before a spawn
/// re-earns trust in the credential from scratch (cache miss => optimistic).
const VALIDATION_CACHE_TTL_SECS: u64 = 300;

fn validation_cache_path() -> PathBuf {
    if let Ok(p) = std::env::var("CHUMP_AUTH_VALIDATION_CACHE") {
        return PathBuf::from(p);
    }
    chump_config_path()
        .parent()
        .map(|d| d.join("auth-validation-cache.tsv"))
        .unwrap_or_else(|| PathBuf::from("/tmp/chump-auth-validation-cache.tsv"))
}

/// Cheap non-cryptographic fingerprint of a credential value — used only to
/// detect "this is the same credential we last validated", never to
/// reconstruct or store the secret itself.
fn fingerprint(value: &str) -> String {
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};
    let mut hasher = DefaultHasher::new();
    value.hash(&mut hasher);
    format!("{:x}", hasher.finish())
}

fn mode_key(mode: &ActiveMode) -> &'static str {
    match mode {
        ActiveMode::ApiKey => "api-key",
        ActiveMode::OAuth => "oauth",
        ActiveMode::None => "none",
    }
}

/// Record whether `mode` (with the credential fingerprinted as `cred`)
/// worked (`alive=true`) or was rejected (`alive=false`) on a real spawn
/// attempt. Appends a row; `cached_validation` reads the most recent row
/// for the (mode, fingerprint) pair.
pub fn record_validation_result(mode: &ActiveMode, cred_value: &str, alive: bool) {
    record_validation_result_at(mode, cred_value, alive, &validation_cache_path());
}

fn record_validation_result_at(mode: &ActiveMode, cred_value: &str, alive: bool, path: &Path) {
    if *mode == ActiveMode::None {
        return;
    }
    let ts = now_secs();
    let row = format!(
        "{}\t{}\t{}\t{}\n",
        mode_key(mode),
        fingerprint(cred_value),
        alive,
        ts
    );
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let _ = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .and_then(|mut f| {
            use std::io::Write;
            f.write_all(row.as_bytes())
        });
}

/// Look up the most recent (fresh, within TTL) validation result for
/// `mode`+`cred_value`. Returns `None` on cache miss, stale entry, or a
/// fingerprint mismatch (credential rotated since the last recorded
/// result) — callers treat `None` as "unknown, proceed optimistically".
fn cached_validation(mode: &ActiveMode, cred_value: &str) -> Option<bool> {
    cached_validation_at(mode, cred_value, &validation_cache_path())
}

fn cached_validation_at(mode: &ActiveMode, cred_value: &str, path: &Path) -> Option<bool> {
    let content = std::fs::read_to_string(path).ok()?;
    let want_mode = mode_key(mode);
    let want_fp = fingerprint(cred_value);
    let now = now_secs();
    // Last matching row wins (most recent observation for this credential).
    let mut result = None;
    for line in content.lines() {
        let mut parts = line.splitn(4, '\t');
        let (m, fp, alive, ts) = (parts.next()?, parts.next()?, parts.next()?, parts.next()?);
        if m != want_mode || fp != want_fp {
            continue;
        }
        let ts: u64 = ts.parse().ok()?;
        if now.saturating_sub(ts) > VALIDATION_CACHE_TTL_SECS {
            continue;
        }
        result = alive.parse::<bool>().ok();
    }
    result
}

fn now_secs() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Resolve auth for an about-to-happen spawn, applying the validate-before-
/// use cached check: if the mode that `resolve()` would pick is cached as
/// recently dead, proactively switch to the fallback credential (emitting
/// `fleet_auth_fallback`) BEFORE the spawn happens, rather than waiting for
/// it to fail live. Cache miss (unknown / stale / no prior observation)
/// behaves exactly like `detect_and_resolve()` — optimistic, fail-open.
pub fn resolve_for_spawn(ambient_path: Option<&Path>) -> ActiveAuth {
    let auth = detect_and_resolve();
    let cred_value = match auth.mode {
        ActiveMode::ApiKey => auth.creds.api_key.as_str(),
        ActiveMode::OAuth => auth.creds.oauth_token.as_str(),
        ActiveMode::None => return auth,
    };
    match cached_validation(&auth.mode, cred_value) {
        Some(false) => auth.on_auth_failure(ambient_path).unwrap_or(auth),
        _ => auth,
    }
}

// ── Detection ──────────────────────────────────────────────────────────────

/// Detect all available credentials from env, refresh file, and config.toml.
/// Call this at startup and before each worker spawn for re-evaluation.
pub fn detect_credentials() -> AuthCredentials {
    let mut creds = AuthCredentials::default();

    // 1. Environment (highest priority)
    creds.api_key = std::env::var("ANTHROPIC_API_KEY")
        .unwrap_or_default()
        .trim()
        .to_string();
    creds.oauth_token = std::env::var("CLAUDE_CODE_OAUTH_TOKEN")
        .unwrap_or_default()
        .trim()
        .to_string();

    // 2. OAUTH refresh file (CHUMP_OAUTH_TOKEN_FILE written by control.sh every 5 min).
    //    Only overrides oauth_token when env is empty.
    //    RESILIENT-1506: CHUMP_OAUTH_TOKEN_FILE is normally exported by
    //    providers.env / run-fleet.sh, not baked into this binary — so a
    //    stripped providers.env line silently dropped this entire source and
    //    took the fleet down (2026-09-28) even though the refresher daemon
    //    kept ~/.chump/oauth-token.json perfectly current the whole time.
    //    Default to that well-known path so the file is read natively
    //    whenever the env var is absent, same as
    //    scripts/dispatch/chump-farmer-run.sh's TOKEN_FILE fallback.
    if creds.oauth_token.is_empty() {
        let tok_path = std::env::var("CHUMP_OAUTH_TOKEN_FILE")
            .ok()
            .filter(|s| !s.trim().is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(default_oauth_token_file);
        if let Some(tok) = read_oauth_token_file(&tok_path) {
            creds.oauth_token = tok;
        }
    }

    // 3. ~/.chump/config.toml — fills blanks not covered by env or refresh file
    if creds.api_key.is_empty() || creds.oauth_token.is_empty() {
        if let Some(cfg) = read_config_toml(&chump_config_path()) {
            if creds.api_key.is_empty() {
                creds.api_key = cfg.api_key;
            }
            if creds.oauth_token.is_empty() {
                creds.oauth_token = cfg.oauth_token;
            }
        }
    }

    creds
}

/// Resolve which auth mode to activate given operator preference and available creds.
pub fn resolve(creds: AuthCredentials) -> ActiveAuth {
    let mode = match AuthMode::from_env() {
        AuthMode::ApiKey => {
            if creds.has_api_key() {
                ActiveMode::ApiKey
            } else {
                ActiveMode::None
            }
        }
        AuthMode::OAuth => {
            if creds.has_oauth() {
                ActiveMode::OAuth
            } else {
                ActiveMode::None
            }
        }
        AuthMode::Auto => {
            // RESILIENT-057: OAUTH is cost-primary — prefer it when present.
            // ANTHROPIC_API_KEY is the non-expiring fallback floor, used
            // only when OAUTH is absent.
            if creds.has_oauth() {
                ActiveMode::OAuth
            } else if creds.has_api_key() {
                ActiveMode::ApiKey
            } else {
                ActiveMode::None
            }
        }
    };
    ActiveAuth { mode, creds }
}

/// Convenience: detect + resolve in one call. Use before each worker spawn.
pub fn detect_and_resolve() -> ActiveAuth {
    resolve(detect_credentials())
}

// ── Fleet doctor ───────────────────────────────────────────────────────────

#[derive(Debug)]
pub struct DoctorReport {
    pub api_key_ok: bool,
    pub oauth_ok: bool,
    pub active_mode: ActiveMode,
    pub warnings: Vec<String>,
}

/// Validates both auth paths and returns a report. Used by `chump fleet doctor`.
pub fn fleet_doctor_validate() -> DoctorReport {
    let creds = detect_credentials();
    let auth = resolve(creds.clone());

    let mut warnings = Vec::new();

    if !creds.has_api_key() && !creds.has_oauth() {
        warnings.push(
            "No auth credentials found. Set ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN.".into(),
        );
    }

    let mode_env = std::env::var("CHUMP_AUTH_MODE").unwrap_or_else(|_| "auto".into());
    if mode_env.eq_ignore_ascii_case("api-key") && !creds.has_api_key() {
        warnings.push("CHUMP_AUTH_MODE=api-key but ANTHROPIC_API_KEY is absent or empty.".into());
    }
    if mode_env.eq_ignore_ascii_case("oauth") && !creds.has_oauth() {
        warnings.push(
            "CHUMP_AUTH_MODE=oauth but no OAUTH token found (env, refresh file, or config.toml)."
                .into(),
        );
    }
    if auth.mode == ActiveMode::None {
        warnings
            .push("Resolved auth mode is None — workers will fail at first claude -p call.".into());
    }
    if creds.has_api_key() && creds.has_oauth() {
        // Both present: make the active choice visible.
        let inactive = if auth.mode == ActiveMode::ApiKey {
            "OAUTH"
        } else {
            "API key"
        };
        warnings.push(format!(
            "Both API key and OAUTH token present. {inactive} is configured as fallback only."
        ));
    }

    DoctorReport {
        api_key_ok: creds.has_api_key(),
        oauth_ok: creds.has_oauth(),
        active_mode: auth.mode,
        warnings,
    }
}

// ── EFFECTIVE-018: pluggable per-provider credential layer ────────────────
//
// Sibling to the existing Anthropic-only AuthCredentials/ActiveAuth. The
// chump-first doctrine requires non-Anthropic operators (Ollama, Groq,
// Together, OpenAI, ...) to authenticate too. Existing Anthropic paths
// remain backwards-compatible — this layer is additive.

/// Generic per-provider credentials. Each provider has its own env-var
/// conventions; this struct normalizes them.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Credentials {
    /// Provider name (anthropic, openai, together, groq, cerebras, nvidia,
    /// ollama, custom). Lowercase.
    pub provider: String,
    /// API key, if the provider uses one.
    pub api_key: Option<String>,
    /// OAuth token (Anthropic-only today; placeholder for future).
    pub oauth_token: Option<String>,
    /// Base URL override (e.g., http://localhost:11434 for Ollama, or a
    /// self-hosted OpenAI-compatible endpoint).
    pub base_url: Option<String>,
}

impl Credentials {
    /// True when the provider has at least one credential or doesn't need
    /// one (e.g., Ollama at localhost works with no key).
    pub fn is_usable(&self) -> bool {
        match self.provider.as_str() {
            // Ollama needs no API key at localhost; just having the binary
            // running is enough. base_url is optional.
            "ollama" => true,
            // Every other provider needs an api_key (or oauth for anthropic).
            "anthropic" => {
                self.api_key
                    .as_deref()
                    .is_some_and(|s| !s.trim().is_empty())
                    || self
                        .oauth_token
                        .as_deref()
                        .is_some_and(|s| !s.trim().is_empty())
            }
            _ => self
                .api_key
                .as_deref()
                .is_some_and(|s| !s.trim().is_empty()),
        }
    }
}

/// Returns `(api_key_env_var, oauth_env_var, base_url_env_var)` for a given
/// provider. `None` values mean the provider doesn't use that credential
/// type.
fn provider_env_pattern(
    provider: &str,
) -> (
    Option<&'static str>,
    Option<&'static str>,
    Option<&'static str>,
) {
    match provider {
        "anthropic" => (
            Some("ANTHROPIC_API_KEY"),
            Some("CLAUDE_CODE_OAUTH_TOKEN"),
            None,
        ),
        "openai" => (Some("OPENAI_API_KEY"), None, Some("OPENAI_API_BASE")),
        "together" => (Some("TOGETHER_API_KEY"), None, Some("TOGETHER_API_BASE")),
        "groq" => (Some("GROQ_API_KEY"), None, Some("GROQ_API_BASE")),
        "cerebras" => (Some("CEREBRAS_API_KEY"), None, Some("CEREBRAS_API_BASE")),
        "nvidia" => (Some("NVIDIA_API_KEY"), None, Some("NVIDIA_API_BASE")),
        "ollama" => (None, None, Some("OLLAMA_BASE_URL")),
        "custom" => (
            Some("CHUMP_CUSTOM_API_KEY"),
            None,
            Some("CHUMP_CUSTOM_BASE_URL"),
        ),
        _ => (None, None, None),
    }
}

/// Read env var, returning `None` if unset or empty after trim.
fn env_nonempty(var: &str) -> Option<String> {
    let val = std::env::var(var).ok()?;
    let trimmed = val.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

/// Detect credentials for a specific provider from env vars.
///
/// For Anthropic, also falls back to the existing OAUTH refresh file +
/// config.toml machinery so existing operators are unaffected.
pub fn detect_credentials_for(provider: &str) -> Credentials {
    let provider = provider.to_ascii_lowercase();
    let (api_var, oauth_var, base_var) = provider_env_pattern(&provider);

    let mut creds = Credentials {
        provider: provider.clone(),
        api_key: api_var.and_then(env_nonempty),
        oauth_token: oauth_var.and_then(env_nonempty),
        base_url: base_var.and_then(env_nonempty),
    };

    // Anthropic backwards-compat: if env vars miss, walk the existing
    // refresh-file + config.toml chain (covers operator's existing setup).
    if provider == "anthropic" && !creds.is_usable() {
        let legacy = detect_credentials(); // existing function
        let has_key = legacy.has_api_key();
        let has_oauth = legacy.has_oauth();
        if creds.api_key.is_none() && has_key {
            creds.api_key = Some(legacy.api_key.clone());
        }
        if creds.oauth_token.is_none() && has_oauth {
            creds.oauth_token = Some(legacy.oauth_token);
        }
    }

    creds
}

/// All providers chump knows about. Used by `fleet_doctor_validate_all` to
/// report which are configured.
pub const KNOWN_PROVIDERS: &[&str] = &[
    "anthropic",
    "openai",
    "together",
    "groq",
    "cerebras",
    "nvidia",
    "ollama",
    "custom",
];

/// Multi-provider doctor report. Lists each provider's status.
#[derive(Debug)]
pub struct MultiProviderReport {
    pub per_provider: Vec<(String, Credentials)>,
}

impl MultiProviderReport {
    /// Count of providers with usable credentials.
    pub fn usable_count(&self) -> usize {
        self.per_provider
            .iter()
            .filter(|(_, c)| c.is_usable())
            .count()
    }

    /// True when at least one provider is usable. Per EFFECTIVE-018 AC:
    /// `chump fleet doctor` exits non-zero only if ALL providers fail.
    pub fn any_usable(&self) -> bool {
        self.usable_count() > 0
    }
}

/// EFFECTIVE-018: validate every known provider's credential availability.
/// Returns a report listing which providers have usable creds. Used by
/// `chump fleet doctor` to surface which workers the operator can actually
/// run (claude/opencode/aider all reach Anthropic; ollama-loop reaches
/// Ollama; etc.).
pub fn fleet_doctor_validate_all() -> MultiProviderReport {
    let per_provider = KNOWN_PROVIDERS
        .iter()
        .map(|p| (p.to_string(), detect_credentials_for(p)))
        .collect();
    MultiProviderReport { per_provider }
}

// ── Internal helpers ───────────────────────────────────────────────────────

/// Parse a JSON token file written by control.sh:
/// `{"token":"sk-ant-oat01-...","written_at":"...","source":"..."}` or
/// `{"access_token":"..."}` (Claude Code's own format).
fn read_oauth_token_file(path: &Path) -> Option<String> {
    let raw = std::fs::read_to_string(path).ok()?;
    // Try the fields we know about.
    for key in &["token", "access_token", "claudeAiOauthToken"] {
        if let Some(tok) = extract_json_string(&raw, key) {
            if !tok.is_empty() {
                return Some(tok);
            }
        }
    }
    None
}

/// Extremely minimal JSON string extractor — avoids pulling in serde just for auth.
/// Finds `"key":"value"` in a flat JSON object.
fn extract_json_string(json: &str, key: &str) -> Option<String> {
    let needle = format!("\"{}\"", key);
    let start = json.find(&needle)? + needle.len();
    let after = json[start..].trim_start();
    let after = after.strip_prefix(':')?.trim_start();
    let after = after.strip_prefix('"')?;
    let end = after.find('"')?;
    Some(after[..end].to_string())
}

/// Parse the subset of ~/.chump/config.toml relevant to auth.
fn read_config_toml(path: &Path) -> Option<AuthCredentials> {
    let content = std::fs::read_to_string(path).ok()?;
    let mut creds = AuthCredentials::default();
    let mut in_api = false;

    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with('[') {
            in_api = trimmed == "[api]";
            continue;
        }
        if !in_api || trimmed.starts_with('#') {
            continue;
        }
        if let Some((k, v)) = parse_toml_kv(trimmed) {
            match k {
                "anthropic_api_key" => creds.api_key = v.to_string(),
                "claude_code_oauth_token" => creds.oauth_token = v.to_string(),
                _ => {}
            }
        }
    }

    if creds.has_api_key() || creds.has_oauth() {
        Some(creds)
    } else {
        None
    }
}

/// Parse `key = "value"` or `key = value` (no quotes) from a TOML line.
fn parse_toml_kv(line: &str) -> Option<(&str, &str)> {
    let (k, rest) = line.split_once('=')?;
    let k = k.trim();
    let v = rest.trim().trim_matches('"');
    Some((k, v))
}

pub(crate) fn chump_config_path() -> PathBuf {
    let home = std::env::var("CHUMP_HOME")
        .or_else(|_| std::env::var("HOME"))
        .unwrap_or_else(|_| "/tmp".into());
    PathBuf::from(home).join(".chump").join("config.toml")
}

/// The well-known oauth-token.json path the refresher daemon keeps current
/// (RESILIENT-1506), used as the fallback when CHUMP_OAUTH_TOKEN_FILE is unset.
fn default_oauth_token_file() -> PathBuf {
    let home = std::env::var("CHUMP_HOME")
        .or_else(|_| std::env::var("HOME"))
        .unwrap_or_else(|_| "/tmp".into());
    PathBuf::from(home).join(".chump").join("oauth-token.json")
}

/// Read a single `key = "value"` from a named section of ~/.chump/config.toml.
/// Returns `None` if the file is missing, the section absent, or the key
/// not set. Used by INFRA-988 for non-secret settings stored under `[settings]`.
pub(crate) fn read_config_kv(section: &str, key: &str) -> Option<String> {
    let path = chump_config_path();
    let content = std::fs::read_to_string(&path).ok()?;
    let target_section = format!("[{}]", section);
    let mut in_section = false;
    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with('[') {
            in_section = trimmed == target_section;
            continue;
        }
        if !in_section || trimmed.starts_with('#') || trimmed.is_empty() {
            continue;
        }
        if let Some((k, v)) = parse_toml_kv(trimmed) {
            if k == key {
                return Some(v.to_string());
            }
        }
    }
    None
}

/// Upsert `key = "value"` in a named section of ~/.chump/config.toml.
/// Creates the file (with `chmod 600` on Unix) and section if absent.
/// Used by INFRA-988 for the PWA settings panel — never writes secrets
/// (the secret-flow gap INFRA-989 owns that path separately).
pub(crate) fn write_config_kv(section: &str, key: &str, value: &str) -> std::io::Result<()> {
    let path = chump_config_path();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let existing = std::fs::read_to_string(&path).unwrap_or_default();
    let target_section = format!("[{}]", section);

    let mut out = String::new();
    let mut in_section = false;
    let mut written = false;
    let mut section_seen = false;

    for line in existing.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with('[') {
            if in_section && !written {
                out.push_str(&format!("{} = \"{}\"\n", key, value));
                written = true;
            }
            in_section = trimmed == target_section;
            if in_section {
                section_seen = true;
            }
            out.push_str(line);
            out.push('\n');
            continue;
        }
        if in_section && !written {
            if let Some((k, _)) = parse_toml_kv(trimmed) {
                if k == key {
                    out.push_str(&format!("{} = \"{}\"\n", key, value));
                    written = true;
                    continue;
                }
            }
        }
        out.push_str(line);
        out.push('\n');
    }

    if !written {
        if !section_seen {
            if !out.is_empty() && !out.ends_with('\n') {
                out.push('\n');
            }
            out.push_str(&format!("\n{}\n", target_section));
        }
        out.push_str(&format!("{} = \"{}\"\n", key, value));
    }

    std::fs::write(&path, out)?;

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = std::fs::metadata(&path)?.permissions();
        perms.set_mode(0o600);
        std::fs::set_permissions(&path, perms)?;
    }

    Ok(())
}

fn chrono_ts() -> String {
    // RFC3339-ish without pulling in chrono. Good enough for ambient log.
    use std::time::{SystemTime, UNIX_EPOCH};
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    // Format as approximate ISO8601 — operators use this for "recent?" checks only.
    let (y, mo, d, h, mi, s) = secs_to_ymd_hms(secs);
    format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}Z")
}

fn secs_to_ymd_hms(secs: u64) -> (u32, u32, u32, u32, u32, u32) {
    let s = (secs % 60) as u32;
    let m = ((secs / 60) % 60) as u32;
    let h = ((secs / 3600) % 24) as u32;
    let days = (secs / 86400) as u32;
    // Gregorian calendar approximation (good until 2100)
    let z = days + 719468;
    let era = z / 146097;
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let mo = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if mo <= 2 { y + 1 } else { y };
    (y, mo, d, h, m, s)
}

fn emit_ambient(path: Option<&Path>, event: &str) {
    let p = path.map(|p| p.to_path_buf()).unwrap_or_else(|| {
        PathBuf::from(
            std::env::var("CHUMP_AMBIENT_LOG")
                .unwrap_or_else(|_| ".chump-locks/ambient.jsonl".into()),
        )
    });
    let _ = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&p)
        .and_then(|mut f| {
            use std::io::Write;
            f.write_all(event.as_bytes())
        });
}

// ── Tests ───────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    // Env var tests must be serialized — env is process-global.
    static ENV_LOCK: Mutex<()> = Mutex::new(());

    fn with_env<F: FnOnce()>(vars: &[(&str, &str)], cleared: &[&str], f: F) {
        // Recover from poisoning so a single test panic doesn't cascade-fail
        // every other test that tries to mutate env.
        let _guard = ENV_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        // CREDIBLE-133: hermetic config home. Unless a test sets CHUMP_HOME
        // explicitly, point it at a fresh empty temp dir so credential detection
        // (source 3 = ~/.chump/config.toml via chump_config_path) never reads the
        // developer's REAL config — which on a live box holds real creds and breaks
        // the "no creds" / "no oauth" assertions. CHUMP_HOME is always saved+restored.
        let sets_chump_home = vars.iter().any(|(k, _)| *k == "CHUMP_HOME");
        let saved: Vec<(String, Option<String>)> = vars
            .iter()
            .map(|(k, _)| (k.to_string(), std::env::var(k).ok()))
            .chain(
                cleared
                    .iter()
                    .map(|k| (k.to_string(), std::env::var(k).ok())),
            )
            .chain(std::iter::once((
                "CHUMP_HOME".to_string(),
                std::env::var("CHUMP_HOME").ok(),
            )))
            .collect();
        for (k, v) in vars {
            std::env::set_var(k, v);
        }
        for k in cleared {
            std::env::remove_var(k);
        }
        let temp_home = if sets_chump_home {
            None
        } else {
            let d = std::env::temp_dir().join(format!(
                "chump-auth-test-home-{}-{}",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|x| x.as_nanos())
                    .unwrap_or(0)
            ));
            let _ = std::fs::create_dir_all(&d);
            std::env::set_var("CHUMP_HOME", &d);
            Some(d)
        };
        f();
        for (k, v) in &saved {
            match v {
                Some(val) => std::env::set_var(k, val),
                None => std::env::remove_var(k),
            }
        }
        if let Some(d) = temp_home {
            let _ = std::fs::remove_dir_all(&d);
        }
    }

    // ── Quadrant 1: API key only ────────────────────────────────────────────

    #[test]
    fn api_key_only_resolves_api_key_mode() {
        with_env(
            &[("ANTHROPIC_API_KEY", "sk-ant-key123")],
            &[
                "CLAUDE_CODE_OAUTH_TOKEN",
                "CHUMP_AUTH_MODE",
                "CHUMP_OAUTH_TOKEN_FILE",
                "CHUMP_HOME",
            ],
            || {
                let auth = detect_and_resolve();
                assert_eq!(auth.mode, ActiveMode::ApiKey);
                assert!(auth.creds.has_api_key());
                assert!(!auth.creds.has_oauth());
                let pairs = auth.env_pairs();
                assert!(pairs
                    .iter()
                    .any(|(k, v)| k == "ANTHROPIC_API_KEY" && v == "sk-ant-key123"));
                assert!(pairs
                    .iter()
                    .any(|(k, v)| k == "CLAUDE_CODE_OAUTH_TOKEN" && v.is_empty()));
            },
        );
    }

    // ── Quadrant 2: OAUTH only ─────────────────────────────────────────────

    #[test]
    fn oauth_only_resolves_oauth_mode() {
        with_env(
            &[("CLAUDE_CODE_OAUTH_TOKEN", "sk-ant-oat01-tok")],
            &[
                "ANTHROPIC_API_KEY",
                "CHUMP_AUTH_MODE",
                "CHUMP_OAUTH_TOKEN_FILE",
                "CHUMP_HOME",
            ],
            || {
                let auth = detect_and_resolve();
                assert_eq!(auth.mode, ActiveMode::OAuth);
                assert!(!auth.creds.has_api_key());
                assert!(auth.creds.has_oauth());
                let pairs = auth.env_pairs();
                assert!(pairs
                    .iter()
                    .any(|(k, v)| k == "CLAUDE_CODE_OAUTH_TOKEN" && v == "sk-ant-oat01-tok"));
                assert!(pairs
                    .iter()
                    .any(|(k, v)| k == "ANTHROPIC_API_KEY" && v.is_empty()));
            },
        );
    }

    // ── Quadrant 3: both present — OAUTH preferred in auto mode (RESILIENT-057) ──

    #[test]
    fn both_present_auto_prefers_oauth() {
        with_env(
            &[
                ("ANTHROPIC_API_KEY", "sk-ant-key"),
                ("CLAUDE_CODE_OAUTH_TOKEN", "sk-ant-oat01-tok"),
            ],
            &["CHUMP_AUTH_MODE", "CHUMP_OAUTH_TOKEN_FILE", "CHUMP_HOME"],
            || {
                let auth = detect_and_resolve();
                assert_eq!(auth.mode, ActiveMode::OAuth);
                assert!(auth.creds.has_api_key());
                assert!(auth.creds.has_oauth());
            },
        );
    }

    #[test]
    fn both_present_mode_override_forces_oauth() {
        with_env(
            &[
                ("ANTHROPIC_API_KEY", "sk-ant-key"),
                ("CLAUDE_CODE_OAUTH_TOKEN", "sk-ant-oat01-tok"),
                ("CHUMP_AUTH_MODE", "oauth"),
            ],
            &["CHUMP_OAUTH_TOKEN_FILE", "CHUMP_HOME"],
            || {
                let auth = detect_and_resolve();
                assert_eq!(auth.mode, ActiveMode::OAuth);
            },
        );
    }

    // ── Quadrant 4: neither present ────────────────────────────────────────

    #[test]
    fn neither_present_resolves_none() {
        with_env(
            &[],
            &[
                "ANTHROPIC_API_KEY",
                "CLAUDE_CODE_OAUTH_TOKEN",
                "CHUMP_AUTH_MODE",
                "CHUMP_OAUTH_TOKEN_FILE",
                "CHUMP_HOME",
            ],
            || {
                let auth = detect_and_resolve();
                assert_eq!(auth.mode, ActiveMode::None);
                assert!(auth.is_none());
                assert!(auth.env_pairs().is_empty());
            },
        );
    }

    // ── Fallback (401 handling) ─────────────────────────────────────────────

    #[test]
    fn api_key_fallback_to_oauth_on_401() {
        let creds = AuthCredentials {
            api_key: "sk-ant-key".into(),
            oauth_token: "sk-ant-oat01-tok".into(),
        };
        let auth = ActiveAuth {
            mode: ActiveMode::ApiKey,
            creds,
        };
        let fallback = auth.on_auth_failure(None);
        assert!(fallback.is_some());
        let fb = fallback.unwrap();
        assert_eq!(fb.mode, ActiveMode::OAuth);
    }

    #[test]
    fn oauth_fallback_to_api_key_on_401() {
        let creds = AuthCredentials {
            api_key: "sk-ant-key".into(),
            oauth_token: "sk-ant-oat01-tok".into(),
        };
        let auth = ActiveAuth {
            mode: ActiveMode::OAuth,
            creds,
        };
        let fallback = auth.on_auth_failure(None);
        assert!(fallback.is_some());
        assert_eq!(fallback.unwrap().mode, ActiveMode::ApiKey);
    }

    // ── RESILIENT-057: fail-open failure classification (AC4) ──────────────

    #[test]
    fn classify_401_as_unauthorized() {
        assert_eq!(
            AuthFailureKind::classify("HTTP 401 Unauthorized: invalid api key"),
            AuthFailureKind::Unauthorized
        );
    }

    #[test]
    fn classify_network_timeout_as_transient() {
        assert_eq!(
            AuthFailureKind::classify("request timed out after 30s"),
            AuthFailureKind::Transient
        );
        assert_eq!(
            AuthFailureKind::classify("429 rate limit exceeded, retry later"),
            AuthFailureKind::Transient
        );
        assert_eq!(
            AuthFailureKind::classify("503 Service Temporarily Unavailable"),
            AuthFailureKind::Transient
        );
    }

    #[test]
    fn on_auth_failure_classified_does_not_fall_back_on_transient_error() {
        let creds = AuthCredentials {
            api_key: "sk-ant-key".into(),
            oauth_token: "sk-ant-oat01-tok".into(),
        };
        let auth = ActiveAuth {
            mode: ActiveMode::OAuth,
            creds,
        };
        // A network timeout must NOT burn OAUTH's standing / fall back to
        // the API key floor (AC4: fail-open).
        let result = auth.on_auth_failure_classified("connection timed out", None);
        assert!(result.is_none());
    }

    #[test]
    fn on_auth_failure_classified_falls_back_on_real_unauthorized() {
        let creds = AuthCredentials {
            api_key: "sk-ant-key".into(),
            oauth_token: "sk-ant-oat01-tok".into(),
        };
        let auth = ActiveAuth {
            mode: ActiveMode::OAuth,
            creds,
        };
        let result = auth.on_auth_failure_classified("401 unauthorized: token expired", None);
        assert_eq!(result.map(|a| a.mode), Some(ActiveMode::ApiKey));
    }

    #[test]
    fn no_fallback_when_only_one_cred() {
        let creds = AuthCredentials {
            api_key: "sk-ant-key".into(),
            oauth_token: String::new(),
        };
        let auth = ActiveAuth {
            mode: ActiveMode::ApiKey,
            creds,
        };
        let fallback = auth.on_auth_failure(None);
        assert!(fallback.is_none());
    }

    // ── OAuth token file ───────────────────────────────────────────────────

    #[test]
    fn reads_oauth_token_from_refresh_file() {
        let dir = tempfile::tempdir().unwrap();
        let tok_path = dir.path().join("oauth-token.json");
        std::fs::write(
            &tok_path,
            r#"{"token":"sk-ant-oat01-fresh","written_at":"2026-05-06T00:00:00Z"}"#,
        )
        .unwrap();

        with_env(
            &[("CHUMP_OAUTH_TOKEN_FILE", tok_path.to_str().unwrap())],
            &[
                "ANTHROPIC_API_KEY",
                "CLAUDE_CODE_OAUTH_TOKEN",
                "CHUMP_AUTH_MODE",
                "CHUMP_HOME",
            ],
            || {
                let creds = detect_credentials();
                assert_eq!(creds.oauth_token, "sk-ant-oat01-fresh");
            },
        );
    }

    #[test]
    fn reads_oauth_token_from_default_path_when_env_var_unset() {
        // RESILIENT-1506: CHUMP_OAUTH_TOKEN_FILE not exported (providers.env
        // stripped) must still find ~/.chump/oauth-token.json natively.
        let dir = tempfile::tempdir().unwrap();
        let chump_dir = dir.path().join(".chump");
        std::fs::create_dir_all(&chump_dir).unwrap();
        std::fs::write(
            chump_dir.join("oauth-token.json"),
            r#"{"token":"sk-ant-oat01-default-path","written_at":"2026-09-28T00:00:00Z"}"#,
        )
        .unwrap();

        with_env(
            &[("CHUMP_HOME", dir.path().to_str().unwrap())],
            &[
                "ANTHROPIC_API_KEY",
                "CLAUDE_CODE_OAUTH_TOKEN",
                "CHUMP_AUTH_MODE",
                "CHUMP_OAUTH_TOKEN_FILE",
            ],
            || {
                let creds = detect_credentials();
                assert_eq!(creds.oauth_token, "sk-ant-oat01-default-path");
            },
        );
    }

    #[test]
    fn config_toml_parsed_correctly() {
        let dir = tempfile::tempdir().unwrap();
        let cfg = dir.path().join("config.toml");
        std::fs::write(&cfg, "[api]\nanthropic_api_key = \"sk-ant-cfgkey\"\n").unwrap();

        let result = read_config_toml(&cfg);
        assert!(result.is_some());
        let creds = result.unwrap();
        assert_eq!(creds.api_key, "sk-ant-cfgkey");
    }

    // ── JSON extractor ─────────────────────────────────────────────────────

    #[test]
    fn extract_json_string_basic() {
        let json = r#"{"token":"sk-ant-oat01-test","written_at":"2026-05-06"}"#;
        assert_eq!(
            extract_json_string(json, "token"),
            Some("sk-ant-oat01-test".into())
        );
    }

    #[test]
    fn extract_json_string_access_token() {
        let json = r#"{"access_token":"bearer-tok","expires_in":3600}"#;
        assert_eq!(
            extract_json_string(json, "access_token"),
            Some("bearer-tok".into())
        );
    }

    // ── Fleet doctor ───────────────────────────────────────────────────────

    #[test]
    fn fleet_doctor_warns_when_no_creds() {
        with_env(
            &[],
            &[
                "ANTHROPIC_API_KEY",
                "CLAUDE_CODE_OAUTH_TOKEN",
                "CHUMP_AUTH_MODE",
                "CHUMP_OAUTH_TOKEN_FILE",
                "CHUMP_HOME",
            ],
            || {
                let report = fleet_doctor_validate();
                assert!(!report.api_key_ok);
                assert!(!report.oauth_ok);
                assert_eq!(report.active_mode, ActiveMode::None);
                assert!(!report.warnings.is_empty());
            },
        );
    }

    #[test]
    fn fleet_doctor_clean_with_api_key() {
        with_env(
            &[("ANTHROPIC_API_KEY", "sk-ant-key")],
            &[
                "CLAUDE_CODE_OAUTH_TOKEN",
                "CHUMP_AUTH_MODE",
                "CHUMP_OAUTH_TOKEN_FILE",
                "CHUMP_HOME",
            ],
            || {
                let report = fleet_doctor_validate();
                assert!(report.api_key_ok);
                assert_eq!(report.active_mode, ActiveMode::ApiKey);
                // No critical warnings (might have "both present" note, but not error warnings)
                let has_error = report.warnings.iter().any(|w| w.contains("will fail"));
                assert!(!has_error);
            },
        );
    }

    // ── RESILIENT-057: validate-before-use cache + spawn-site fallback ─────

    #[test]
    fn validation_cache_round_trips_and_respects_fingerprint() {
        let dir = tempfile::tempdir().unwrap();
        let cache = dir.path().join("auth-validation-cache.tsv");

        assert_eq!(
            cached_validation_at(&ActiveMode::OAuth, "tok-a", &cache),
            None
        );

        record_validation_result_at(&ActiveMode::OAuth, "tok-a", false, &cache);
        assert_eq!(
            cached_validation_at(&ActiveMode::OAuth, "tok-a", &cache),
            Some(false)
        );

        // Different credential value (e.g. after refresh) => cache miss,
        // not a stale "dead" verdict carried over.
        assert_eq!(
            cached_validation_at(&ActiveMode::OAuth, "tok-b", &cache),
            None
        );

        record_validation_result_at(&ActiveMode::OAuth, "tok-a", true, &cache);
        assert_eq!(
            cached_validation_at(&ActiveMode::OAuth, "tok-a", &cache),
            Some(true)
        );
    }

    /// AC5 regression test: OAUTH cached as recently dead + API key present
    /// => resolve_for_spawn proactively picks ApiKey mode and emits
    /// `fleet_auth_fallback` BEFORE the spawn, instead of letting every
    /// worker independently discover the dead OAUTH token live.
    #[test]
    fn dead_oauth_with_api_key_falls_back_to_api_key_and_emits_event() {
        with_env(
            &[
                ("ANTHROPIC_API_KEY", "sk-ant-key"),
                ("CLAUDE_CODE_OAUTH_TOKEN", "sk-ant-oat01-dead"),
            ],
            &["CHUMP_AUTH_MODE", "CHUMP_OAUTH_TOKEN_FILE"],
            || {
                let dir = tempfile::tempdir().unwrap();
                let cache = dir.path().join("auth-validation-cache.tsv");
                let ambient = dir.path().join("ambient.jsonl");

                std::env::set_var("CHUMP_AUTH_VALIDATION_CACHE", &cache);
                record_validation_result_at(&ActiveMode::OAuth, "sk-ant-oat01-dead", false, &cache);

                // Sanity: without the cached-dead signal, auto mode would
                // pick OAuth (RESILIENT-057 AC1).
                assert_eq!(detect_and_resolve().mode, ActiveMode::OAuth);

                let auth = resolve_for_spawn(Some(&ambient));
                assert_eq!(auth.mode, ActiveMode::ApiKey);

                let log = std::fs::read_to_string(&ambient).unwrap_or_default();
                assert!(
                    log.contains("\"kind\":\"fleet_auth_fallback\""),
                    "expected fleet_auth_fallback event, got: {log}"
                );
                assert!(log.contains("\"fallback_mode\":\"apikey\""));

                std::env::remove_var("CHUMP_AUTH_VALIDATION_CACHE");
            },
        );
    }

    #[test]
    fn resolve_for_spawn_optimistic_on_cache_miss() {
        with_env(
            &[("ANTHROPIC_API_KEY", "sk-ant-key")],
            &[
                "CLAUDE_CODE_OAUTH_TOKEN",
                "CHUMP_AUTH_MODE",
                "CHUMP_OAUTH_TOKEN_FILE",
            ],
            || {
                let dir = tempfile::tempdir().unwrap();
                let cache = dir.path().join("auth-validation-cache.tsv");
                std::env::set_var("CHUMP_AUTH_VALIDATION_CACHE", &cache);

                // No prior observation recorded => proceed with the normal
                // resolve() result, unchanged.
                let auth = resolve_for_spawn(None);
                assert_eq!(auth.mode, ActiveMode::ApiKey);

                std::env::remove_var("CHUMP_AUTH_VALIDATION_CACHE");
            },
        );
    }

    // ── EFFECTIVE-018: multi-provider credentials ──────────────────────────

    #[test]
    fn provider_env_pattern_known_providers() {
        // Sanity: each known provider returns a non-empty pattern.
        for p in KNOWN_PROVIDERS {
            let pat = provider_env_pattern(p);
            // Every provider has either api_key or base_url set.
            assert!(
                pat.0.is_some() || pat.2.is_some(),
                "provider {p} has neither api_key nor base_url env-var pattern",
            );
        }
    }

    #[test]
    fn detect_credentials_for_groq_reads_groq_api_key() {
        with_env(&[("GROQ_API_KEY", "gsk-test-fixture")], &[], || {
            let creds = detect_credentials_for("groq");
            assert_eq!(creds.provider, "groq");
            assert_eq!(creds.api_key.as_deref(), Some("gsk-test-fixture"));
            assert!(creds.is_usable());
        });
    }

    #[test]
    fn detect_credentials_for_openai_reads_base_url_too() {
        with_env(
            &[
                ("OPENAI_API_KEY", "sk-test"),
                ("OPENAI_API_BASE", "https://api.example.com/v1"),
            ],
            &[],
            || {
                let creds = detect_credentials_for("openai");
                assert_eq!(creds.api_key.as_deref(), Some("sk-test"));
                assert_eq!(
                    creds.base_url.as_deref(),
                    Some("https://api.example.com/v1")
                );
                assert!(creds.is_usable());
            },
        );
    }

    #[test]
    fn ollama_is_usable_without_api_key() {
        with_env(&[], &["OLLAMA_BASE_URL"], || {
            let creds = detect_credentials_for("ollama");
            assert_eq!(creds.provider, "ollama");
            assert!(creds.api_key.is_none());
            // Per is_usable(): ollama works at localhost without a key.
            assert!(creds.is_usable());
        });
    }

    #[test]
    fn ollama_carries_base_url_override_when_set() {
        with_env(
            &[("OLLAMA_BASE_URL", "http://192.168.1.10:11434")],
            &[],
            || {
                let creds = detect_credentials_for("ollama");
                assert_eq!(creds.base_url.as_deref(), Some("http://192.168.1.10:11434"));
            },
        );
    }

    #[test]
    fn unknown_provider_returns_empty_credentials() {
        with_env(&[], &[], || {
            let creds = detect_credentials_for("notreal");
            assert_eq!(creds.provider, "notreal");
            assert!(creds.api_key.is_none());
            assert!(creds.oauth_token.is_none());
            assert!(creds.base_url.is_none());
            // Not in KNOWN_PROVIDERS; falls through is_usable's default to require api_key.
            assert!(!creds.is_usable());
        });
    }

    #[test]
    fn anthropic_provider_falls_back_to_legacy_chain() {
        // Existing config.toml / refresh-file paths must still work when
        // env vars are unset — backwards compat for Anthropic operators.
        let tmp = tempfile::tempdir().unwrap();
        let chump_dir = tmp.path().join(".chump");
        std::fs::create_dir_all(&chump_dir).unwrap();
        let cfg = chump_dir.join("config.toml");
        std::fs::write(&cfg, "[api]\nanthropic_api_key = \"sk-ant-config-test\"\n").unwrap();

        with_env(
            &[("CHUMP_HOME", tmp.path().to_str().unwrap())],
            &[
                "ANTHROPIC_API_KEY",
                "CLAUDE_CODE_OAUTH_TOKEN",
                "CHUMP_OAUTH_TOKEN_FILE",
            ],
            || {
                let creds = detect_credentials_for("anthropic");
                assert_eq!(creds.provider, "anthropic");
                assert_eq!(creds.api_key.as_deref(), Some("sk-ant-config-test"));
                assert!(creds.is_usable());
            },
        );
    }

    #[test]
    fn fleet_doctor_validate_all_lists_every_known_provider() {
        with_env(&[], KNOWN_PROVIDERS, || {
            let report = fleet_doctor_validate_all();
            assert_eq!(report.per_provider.len(), KNOWN_PROVIDERS.len());
            // Ollama always usable (no key); others depend on env.
            let ollama = report
                .per_provider
                .iter()
                .find(|(p, _)| p == "ollama")
                .unwrap();
            assert!(ollama.1.is_usable(), "ollama should always be usable");
        });
    }

    #[test]
    fn fleet_doctor_any_usable_true_when_one_provider_has_creds() {
        with_env(
            &[("GROQ_API_KEY", "gsk-only-groq-set")],
            &[
                "ANTHROPIC_API_KEY",
                "CLAUDE_CODE_OAUTH_TOKEN",
                "OPENAI_API_KEY",
                "TOGETHER_API_KEY",
                "CEREBRAS_API_KEY",
                "NVIDIA_API_KEY",
                "CHUMP_CUSTOM_API_KEY",
            ],
            || {
                let report = fleet_doctor_validate_all();
                assert!(
                    report.any_usable(),
                    "GROQ_API_KEY + Ollama-localhost should make any_usable=true"
                );
                assert!(report.usable_count() >= 2); // groq + ollama
            },
        );
    }
}
