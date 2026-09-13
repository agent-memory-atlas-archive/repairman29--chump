//! INFRA-1718: fleet-mode surface — one line/object exposing auth mode,
//! backend, effort tier, and cost ceiling so agents stop misrouting work to
//! a broken cascade or an unusable auth path.
//!
//! Read-only: no network or `gh` calls. Derived entirely from
//! `auth::detect_credentials`/`auth::resolve`, the `CHUMP_CASCADE_ENABLED`
//! env var, and `budget_tracker::tier_default_cost_usd`. Consumed by both
//! `chump fleet mode` (this module's CLI arm) and `chump --briefing` (which
//! computes it fresh, not cached, per gap).

use crate::auth;
use crate::budget_tracker;

/// One fleet-mode snapshot.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct FleetMode {
    /// "api-key" | "oauth" | "none"
    pub auth_mode: String,
    /// `false` when no usable credential resolved — callers should treat
    /// this as an unblock-first signal.
    pub auth_usable: bool,
    /// "cascade" | "claude-direct"
    pub backend: String,
    /// Effort tier used to derive `cost_ceiling_usd` (xs|s|m|l|xl).
    pub effort_tier: String,
    pub cost_ceiling_usd: f64,
}

/// `CHUMP_CASCADE_ENABLED=1|true` → cascade backend; anything else (unset,
/// "0", "false") → direct Claude backend. Mirrors the check in
/// `provider_cascade.rs` / `system_prompt.rs`.
pub fn cascade_enabled() -> bool {
    std::env::var("CHUMP_CASCADE_ENABLED")
        .map(|v| v == "1" || v.eq_ignore_ascii_case("true"))
        .unwrap_or(false)
}

/// Compute a fresh fleet-mode snapshot for the given effort tier. Pass the
/// empty string to fall back to the "m" default tier.
pub fn compute(effort_tier: &str) -> FleetMode {
    let creds = auth::detect_credentials();
    let active = auth::resolve(creds);
    let auth_mode = match active.mode {
        auth::ActiveMode::ApiKey => "api-key",
        auth::ActiveMode::OAuth => "oauth",
        auth::ActiveMode::None => "none",
    }
    .to_string();
    let auth_usable = !active.is_none();

    let backend = if cascade_enabled() {
        "cascade"
    } else {
        "claude-direct"
    }
    .to_string();

    let effort_tier = if effort_tier.trim().is_empty() {
        "m".to_string()
    } else {
        effort_tier.trim().to_string()
    };
    let cost_ceiling_usd = budget_tracker::tier_default_cost_usd(&effort_tier);

    FleetMode {
        auth_mode,
        auth_usable,
        backend,
        effort_tier,
        cost_ceiling_usd,
    }
}

/// One-line human-readable render, used by `chump fleet mode`.
pub fn render_line(m: &FleetMode) -> String {
    let flag = if m.auth_usable {
        ""
    } else {
        " [AUTH UNUSABLE]"
    };
    format!(
        "fleet-mode: auth={} backend={} effort_tier={} cost_ceiling=${:.2}{}",
        m.auth_mode, m.backend, m.effort_tier, m.cost_ceiling_usd, flag
    )
}

/// Compact JSON render, used by `chump fleet mode --json` and embedded (as
/// the `fleet_mode` key) into `chump --briefing --json`.
pub fn render_json(m: &FleetMode) -> String {
    format!(
        r#"{{"auth_mode":"{}","auth_usable":{},"backend":"{}","effort_tier":"{}","cost_ceiling_usd":{:.2}}}"#,
        m.auth_mode, m.auth_usable, m.backend, m.effort_tier, m.cost_ceiling_usd
    )
}

/// Markdown section render, used by `chump --briefing` (non-JSON path).
pub fn render_markdown_section(m: &FleetMode) -> String {
    format!(
        "## Fleet Mode\n\n- Auth: `{}`{}\n- Backend: `{}`\n- Effort tier: `{}`\n- Cost ceiling: ${:.2}\n\n",
        m.auth_mode,
        if m.auth_usable { "" } else { " **[AUTH UNUSABLE]**" },
        m.backend,
        m.effort_tier,
        m.cost_ceiling_usd
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    // auth::detect_credentials/resolve reads process-wide env vars, so
    // serialize tests that touch them to avoid cross-test races.
    static ENV_LOCK: Mutex<()> = Mutex::new(());

    fn clear_auth_env() {
        std::env::remove_var("ANTHROPIC_API_KEY");
        std::env::remove_var("CLAUDE_CODE_OAUTH_TOKEN");
        std::env::remove_var("CHUMP_AUTH_MODE");
        std::env::remove_var("CHUMP_OAUTH_TOKEN_FILE");
        std::env::remove_var("CHUMP_CASCADE_ENABLED");
        // Isolate on-disk credential sources (CHUMP_HOME/config.toml, refresh
        // file) so ambient login state on a dev box cannot leak an oauth token
        // into these auth-detection tests and flip the resolved mode.
        std::env::set_var(
            "CHUMP_HOME",
            std::env::temp_dir().join(format!("chump-authtest-{}", std::process::id())),
        );
    }

    #[test]
    fn render_line_flags_auth_unusable_when_no_creds() {
        let _guard = ENV_LOCK.lock().unwrap();
        clear_auth_env();
        // HOME-based config.toml fallback could still supply creds on a dev
        // box; force api-key mode with no key present to make this
        // deterministic regardless of ~/.chump/config.toml contents.
        std::env::set_var("CHUMP_AUTH_MODE", "api-key");

        let mode = compute("s");
        assert!(!mode.auth_usable);
        assert_eq!(mode.auth_mode, "none");
        let line = render_line(&mode);
        assert!(line.contains("[AUTH UNUSABLE]"));

        clear_auth_env();
    }

    #[test]
    fn render_line_omits_flag_when_auth_usable() {
        let _guard = ENV_LOCK.lock().unwrap();
        clear_auth_env();
        std::env::set_var("ANTHROPIC_API_KEY", "sk-test-key");

        let mode = compute("s");
        assert!(mode.auth_usable);
        assert_eq!(mode.auth_mode, "api-key");
        let line = render_line(&mode);
        assert!(!line.contains("AUTH UNUSABLE"));

        clear_auth_env();
    }

    #[test]
    fn backend_is_claude_direct_when_cascade_unset() {
        let _guard = ENV_LOCK.lock().unwrap();
        clear_auth_env();
        std::env::set_var("ANTHROPIC_API_KEY", "sk-test-key");

        let mode = compute("m");
        assert_eq!(mode.backend, "claude-direct");

        clear_auth_env();
    }

    #[test]
    fn backend_is_cascade_when_env_enabled() {
        let _guard = ENV_LOCK.lock().unwrap();
        clear_auth_env();
        std::env::set_var("ANTHROPIC_API_KEY", "sk-test-key");
        std::env::set_var("CHUMP_CASCADE_ENABLED", "1");

        let mode = compute("m");
        assert_eq!(mode.backend, "cascade");

        clear_auth_env();
    }

    #[test]
    fn effort_tier_defaults_to_m_when_empty() {
        let mode = compute("");
        assert_eq!(mode.effort_tier, "m");
        assert_eq!(
            mode.cost_ceiling_usd,
            budget_tracker::tier_default_cost_usd("m")
        );
    }

    #[test]
    fn cost_ceiling_matches_tier_default() {
        let mode = compute("xs");
        assert_eq!(
            mode.cost_ceiling_usd,
            budget_tracker::tier_default_cost_usd("xs")
        );
        assert_eq!(mode.effort_tier, "xs");
    }

    #[test]
    fn render_json_contains_all_fields() {
        let mode = compute("l");
        let json = render_json(&mode);
        assert!(json.contains("\"auth_mode\""));
        assert!(json.contains("\"auth_usable\""));
        assert!(json.contains("\"backend\""));
        assert!(json.contains("\"effort_tier\":\"l\""));
        assert!(json.contains("\"cost_ceiling_usd\""));
    }
}
