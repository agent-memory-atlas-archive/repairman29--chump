//! Send a DM via Discord REST API when running in CLI (e.g. heartbeat).
//! When Chump uses the notify tool in CLI mode, the message is queued but not sent.
//! This module sends it via POST /users/@me/channels and POST /channels/{id}/messages
//! so the owner gets DMs from heartbeat rounds without running the Discord bot.

use anyhow::Result;
use reqwest::Client;
use serde_json::json;

const DISCORD_API: &str = "https://discord.com/api/v10";

/// If DISCORD_TOKEN and CHUMP_READY_DM_USER_ID are set, send the message as a DM to that user.
/// No-op if message is empty or env vars are missing. Logs errors but does not fail the process.
pub async fn send_dm_if_configured(message: &str) {
    // Operator standing order (Jeff, 2026-09-13): the fleet must NOT auto-DM
    // the operator anymore — not heartbeat rounds, not `--notify` pipes from
    // watchdog/farmer/morning-briefing scripts, not shim approval prompts, not
    // even halt-class pages. Every caller of THIS function is an automated
    // (scheduled or event-driven) send to the operator, so the whole helper is
    // gated off by default. The one thing kept — the two-way command gateway's
    // REPLIES to a message Jeff sent — never flows through here (the Python
    // gateway sends via its own path, and the command/advisor agents reply via
    // notify-operator.sh's command-reply allowlist). This is reversible by
    // design: set CHUMP_OPERATOR_AUTOPOST_DM=1 (also true/on/yes) to restore
    // the pre-2026-09-13 behavior. Deliberately a plain descriptive name (not a
    // *_BYPASS/_SKIP/_IGNORE var) so it neither reads as a gate-bypass nor
    // counts against the bypass-var debt ceiling.
    if !autopost_dm_enabled() {
        return;
    }
    // RESILIENT-287: never fire a real operator DM from inside a test run.
    // A fleet node runs `cargo test` with providers.env sourced, so
    // DISCORD_TOKEN + CHUMP_READY_DM_USER_ID are set and the "no-op in test
    // env" assumption fails open — that is how discord_shim's approval unit
    // test DM'd the operator "[to:user-9] approve?" at 3:21AM. cfg!(test) is
    // true only when this crate is compiled under `cargo test`, so the live
    // --discord daemon is unaffected. Opt back in for a deliberate send-path
    // test with CHUMP_ALLOW_TEST_DM=1.
    if cfg!(test) && std::env::var_os("CHUMP_ALLOW_TEST_DM").is_none() {
        return;
    }
    let message = message.trim();
    if message.is_empty() {
        return;
    }
    let token = match std::env::var("DISCORD_TOKEN") {
        Ok(t) => t.trim().to_string(),
        Err(_) => return,
    };
    if token.is_empty() {
        return;
    }
    let user_id = match std::env::var("CHUMP_READY_DM_USER_ID") {
        Ok(id) => id.trim().to_string(),
        Err(_) => return,
    };
    if user_id.is_empty() {
        return;
    }
    if let Err(e) = send_dm_impl(&token, &user_id, message).await {
        eprintln!(
            "Notify DM (CLI): {}",
            crate::chump_log::redact(&e.to_string())
        );
    }
}

/// True when the operator has re-enabled automated operator DMs via
/// `CHUMP_OPERATOR_AUTOPOST_DM` (1/true/on/yes, case-insensitive). Default
/// (unset/empty/anything else) is OFF — automated DMs are suppressed. This
/// gates only `send_dm_if_configured` (the operator-DM path); a2a peer
/// messaging (`send_dm_to_user` / `send_channel_message`) is unaffected.
pub fn autopost_dm_enabled() -> bool {
    match std::env::var("CHUMP_OPERATOR_AUTOPOST_DM") {
        Ok(v) => matches!(
            v.trim().to_ascii_lowercase().as_str(),
            "1" | "true" | "on" | "yes"
        ),
        Err(_) => false,
    }
}

/// Send a DM to an arbitrary Discord user (e.g. the other bot for a2a). Uses Bot token.
pub async fn send_dm_to_user(token: &str, user_id: &str, content: &str) -> Result<()> {
    send_dm_impl(token.trim(), user_id.trim(), content).await
}

/// Send a message to a guild channel (e.g. a2a channel so the user can follow along). Uses Bot token.
pub async fn send_channel_message(token: &str, channel_id: u64, content: &str) -> Result<()> {
    let client = Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .build()?;
    let auth = format!("Bot {}", token.trim());
    let content = content.trim();
    let content = if content.len() > 2000 {
        format!("{}…", &content[..1999])
    } else {
        content.to_string()
    };
    let url = format!("{}/channels/{}/messages", DISCORD_API, channel_id);
    let body = json!({ "content": content });
    let resp = client
        .post(&url)
        .header("Authorization", &auth)
        .header("Content-Type", "application/json")
        .json(&body)
        .send()
        .await?;
    if !resp.status().is_success() {
        let status = resp.status();
        let text = resp.text().await.unwrap_or_default();
        anyhow::bail!("Discord channel message {}: {}", status, text);
    }
    Ok(())
}

async fn send_dm_impl(token: &str, user_id: &str, content: &str) -> Result<()> {
    let client = Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .build()?;
    let auth = format!("Bot {}", token);

    // Create DM channel (idempotent for same user)
    let create_url = format!("{}/users/@me/channels", DISCORD_API);
    let body = json!({ "recipient_id": user_id });
    let resp = client
        .post(&create_url)
        .header("Authorization", &auth)
        .header("Content-Type", "application/json")
        .json(&body)
        .send()
        .await?;
    if !resp.status().is_success() {
        let status = resp.status();
        let text = resp.text().await.unwrap_or_default();
        anyhow::bail!("Discord create DM {}: {}", status, text);
    }
    let channel: serde_json::Value = resp.json().await?;
    let channel_id = channel
        .get("id")
        .and_then(|v| v.as_str())
        .ok_or_else(|| anyhow::anyhow!("Discord response missing channel id"))?;

    // Send message (Discord content limit 2000)
    let content = if content.len() > 2000 {
        format!("{}…", &content[..1999])
    } else {
        content.to_string()
    };
    let msg_url = format!("{}/channels/{}/messages", DISCORD_API, channel_id);
    let msg_body = json!({ "content": content });
    let resp = client
        .post(&msg_url)
        .header("Authorization", &auth)
        .header("Content-Type", "application/json")
        .json(&msg_body)
        .send()
        .await?;
    if !resp.status().is_success() {
        let status = resp.status();
        let text = resp.text().await.unwrap_or_default();
        anyhow::bail!("Discord send message {}: {}", status, text);
    }
    Ok(())
}
