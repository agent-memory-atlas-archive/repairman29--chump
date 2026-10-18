//! INFRA-8573: backend selection for `chump gap decompose`.
//!
//! The decompose command historically built its LLM provider with
//! [`crate::provider_cascade::build_provider`], whose last-resort slot on an
//! un-configured node is a localhost Ollama (`http://127.0.0.1:11434/v1`). On
//! build nodes like `cuphead` there is no Ollama daemon *and* no cloud cascade
//! configured, so every decompose died with
//! `could not query http://127.0.0.1:11434/v1/models` /
//! `model HTTP unreachable`. Meanwhile `chump dispatch` on the same node
//! reaches Opus perfectly well through `claude -p` (subscription OAuth on the
//! node).
//!
//! This module gives decompose the *same* `claude -p` reach that dispatch has:
//!
//! - [`ClaudeCliProvider`] implements [`Provider`] by shelling out to
//!   `claude -p --dangerously-skip-permissions`, feeding the combined
//!   system+user prompt on stdin and returning stdout as the completion
//!   (mirrors `dispatch::spawn_headless`'s stdin/EOF contract and reuses
//!   [`crate::auth::resolve_for_spawn`] for credentials).
//! - [`FallthroughProvider`] tries a named, ordered list of providers and, when
//!   every one fails, returns an error that lists *each provider tried, in
//!   order, with its reason* — satisfying "print every provider tried on
//!   failure".
//! - [`build_decompose_provider`] wires the two together per the selected
//!   [`DecomposeBackend`].
//!
//! Selection is by the `--backend` flag or the node's routing config
//! (`CHUMP_WORK_BACKEND`, the same seam `chump dispatch` reads) — never a new
//! `CHUMP_*_BYPASS/SKIP/NO_*` env var.

use anyhow::Result;
use async_trait::async_trait;
use axonerai::provider::{CompletionResponse, Message, Provider, StopReason, Tool};

/// Which backend `chump gap decompose` should use to reach an LLM.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DecomposeBackend {
    /// Default: try the provider cascade first (free-tier / local), then fall
    /// through to `claude -p` if the cascade cannot serve the request. This is
    /// what makes a bare `chump gap decompose <ID>` succeed on a node where the
    /// cascade is unconfigured/Ollama is absent but `claude -p` works.
    Auto,
    /// Cascade only — the historical behavior. Fails hard (listing the cascade)
    /// if the cascade cannot serve the request.
    Cascade,
    /// `claude -p` only — skip the cascade entirely. The explicit choice when a
    /// node is known to have no local/cloud cascade but a working claude CLI.
    Claude,
}

impl DecomposeBackend {
    /// Human-readable label used in error / observability output.
    pub fn label(self) -> &'static str {
        match self {
            DecomposeBackend::Auto => "auto",
            DecomposeBackend::Cascade => "cascade",
            DecomposeBackend::Claude => "claude",
        }
    }

    /// Parse a `--backend <value>` argument. Unknown values are rejected so a
    /// typo never silently routes to the wrong backend.
    pub fn parse_flag(value: &str) -> Result<Self> {
        match value.trim().to_ascii_lowercase().as_str() {
            "auto" => Ok(DecomposeBackend::Auto),
            "cascade" | "local" | "ollama" => Ok(DecomposeBackend::Cascade),
            "claude" | "claude-p" | "headless" => Ok(DecomposeBackend::Claude),
            other => anyhow::bail!("unknown --backend {other:?}; supported: auto, cascade, claude"),
        }
    }

    /// Resolve the backend from an explicit `--backend` flag, else the node's
    /// routing config (`CHUMP_WORK_BACKEND`, the same var `chump dispatch`
    /// honors), else [`DecomposeBackend::Auto`].
    ///
    /// `CHUMP_WORK_BACKEND=claude` → [`DecomposeBackend::Claude`];
    /// `local`/`ollama`/`mlx`/`chump-local` → [`DecomposeBackend::Cascade`];
    /// anything else (including unset) → [`DecomposeBackend::Auto`].
    pub fn resolve(flag: Option<&str>) -> Result<Self> {
        if let Some(v) = flag {
            return Self::parse_flag(v);
        }
        match std::env::var("CHUMP_WORK_BACKEND").as_deref() {
            Ok("claude") => Ok(DecomposeBackend::Claude),
            Ok("local") | Ok("ollama") | Ok("mlx") | Ok("chump-local") => {
                Ok(DecomposeBackend::Cascade)
            }
            _ => Ok(DecomposeBackend::Auto),
        }
    }
}

/// A [`Provider`] backed by the `claude -p` CLI — the same binary + credential
/// path `chump dispatch --backend headless` uses.
///
/// The system prompt and user messages are concatenated into a single prompt
/// written to the child's stdin (mirroring `dispatch::spawn_headless`'s
/// `cat prompt | claude -p` contract — never passing the prompt as a `-p`
/// value, which the CLI's arg parser rejects when it begins with `-`). The
/// child's stdout is returned verbatim as the completion text; decompose's
/// existing `[`..`]` JSON extraction tolerates any surrounding prose.
pub struct ClaudeCliProvider {
    /// Optional `--model` override; empty/`None` uses the node's claude default.
    model: Option<String>,
}

impl ClaudeCliProvider {
    pub fn new(model: Option<String>) -> Self {
        Self { model }
    }

    /// Build the combined prompt sent on stdin.
    fn build_prompt(messages: &[Message], system_prompt: Option<&str>) -> String {
        let mut out = String::new();
        if let Some(sys) = system_prompt {
            if !sys.trim().is_empty() {
                out.push_str("SYSTEM INSTRUCTIONS:\n");
                out.push_str(sys);
                out.push_str("\n\n");
            }
        }
        for m in messages {
            // Label roles so the model keeps system vs. user distinct even
            // though both arrive over one stdin stream.
            let role = if m.role.eq_ignore_ascii_case("assistant") {
                "ASSISTANT"
            } else {
                "USER"
            };
            out.push_str(role);
            out.push_str(":\n");
            out.push_str(&m.content);
            out.push_str("\n\n");
        }
        out
    }

    /// Spawn `claude -p` synchronously (blocking) and return its stdout. Split
    /// out so it is testable and so the async `complete` can run it on a
    /// blocking thread.
    fn run_blocking(model: Option<String>, prompt: String) -> Result<String> {
        use std::io::Write as _;
        use std::process::{Command, Stdio};

        let mut cmd = Command::new("claude");
        cmd.arg("-p").arg("--dangerously-skip-permissions");
        if let Some(m) = model.as_deref().filter(|m| !m.is_empty()) {
            cmd.args(["--model", m]);
        }
        cmd.stdin(Stdio::piped());
        cmd.stdout(Stdio::piped());
        cmd.stderr(Stdio::piped());
        // RESILIENT-362: claude refuses --dangerously-skip-permissions under
        // root unless IS_SANDBOX=1 marks an intentional sandboxed env — same
        // guard dispatch::spawn_headless sets.
        cmd.env("IS_SANDBOX", "1");
        // Inherit the node's resolved Anthropic/OAuth credential exactly the
        // way a headless dispatch does.
        let active_auth = crate::auth::resolve_for_spawn(None);
        for (k, v) in active_auth.env_pairs() {
            cmd.env(k, v);
        }

        let mut child = cmd.spawn().map_err(|e| {
            anyhow::anyhow!("spawn `claude -p` failed (is the claude CLI on PATH?): {e}")
        })?;

        {
            let mut stdin = child
                .stdin
                .take()
                .ok_or_else(|| anyhow::anyhow!("claude -p stdin was not piped"))?;
            stdin
                .write_all(prompt.as_bytes())
                .map_err(|e| anyhow::anyhow!("writing prompt to claude -p stdin: {e}"))?;
            // Drop closes the pipe (EOF) so claude -p knows the prompt is done.
        }

        let output = child
            .wait_with_output()
            .map_err(|e| anyhow::anyhow!("waiting for claude -p: {e}"))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            let code = output.status.code().unwrap_or(-1);
            anyhow::bail!(
                "claude -p exited {code}: {}",
                stderr.trim().chars().take(400).collect::<String>()
            );
        }

        let text = String::from_utf8_lossy(&output.stdout).to_string();
        if text.trim().is_empty() {
            anyhow::bail!("claude -p returned empty output");
        }
        Ok(text)
    }
}

#[async_trait]
impl Provider for ClaudeCliProvider {
    async fn complete(
        &self,
        messages: Vec<Message>,
        _tools: Option<Vec<Tool>>,
        _max_tokens: Option<u32>,
        system_prompt: Option<String>,
    ) -> Result<CompletionResponse> {
        let prompt = Self::build_prompt(&messages, system_prompt.as_deref());
        let model = self.model.clone();
        // claude -p is a blocking subprocess — run it off the async executor.
        let text = tokio::task::spawn_blocking(move || Self::run_blocking(model, prompt))
            .await
            .map_err(|e| anyhow::anyhow!("claude -p task join error: {e}"))??;
        Ok(CompletionResponse {
            text: Some(text),
            tool_calls: Vec::new(),
            stop_reason: StopReason::EndTurn,
        })
    }
}

/// A named provider for the fallthrough chain.
pub struct NamedProvider {
    pub name: String,
    pub provider: Box<dyn Provider + Send + Sync>,
}

/// Tries an ordered list of providers, returning the first success. When every
/// provider fails, returns an error listing each provider tried, in order, with
/// its (truncated) reason — so the operator always sees the full cascade that
/// was attempted rather than just the last error.
pub struct FallthroughProvider {
    providers: Vec<NamedProvider>,
}

impl FallthroughProvider {
    pub fn new(providers: Vec<NamedProvider>) -> Self {
        Self { providers }
    }

    /// Format the "every provider tried" error body from collected failures.
    /// Pure + testable: `attempts` is `(name, reason)` in attempt order.
    pub fn format_all_failed(attempts: &[(String, String)]) -> String {
        let mut s = String::from("all decompose providers failed; tried in order:");
        for (i, (name, reason)) in attempts.iter().enumerate() {
            let reason_1l = reason.replace('\n', " ");
            let reason_trim: String = reason_1l.chars().take(300).collect();
            s.push_str(&format!("\n  {}. {} — {}", i + 1, name, reason_trim));
        }
        if attempts.is_empty() {
            s.push_str("\n  (no providers configured)");
        }
        s
    }
}

#[async_trait]
impl Provider for FallthroughProvider {
    async fn complete(
        &self,
        messages: Vec<Message>,
        tools: Option<Vec<Tool>>,
        max_tokens: Option<u32>,
        system_prompt: Option<String>,
    ) -> Result<CompletionResponse> {
        let mut attempts: Vec<(String, String)> = Vec::new();
        for np in &self.providers {
            match np
                .provider
                .complete(
                    messages.clone(),
                    tools.clone(),
                    max_tokens,
                    system_prompt.clone(),
                )
                .await
            {
                Ok(resp) => {
                    if !attempts.is_empty() {
                        // Make the successful fallthrough visible: which earlier
                        // providers were tried before this one won.
                        let tried: Vec<&str> = attempts.iter().map(|(n, _)| n.as_str()).collect();
                        eprintln!(
                            "chump gap decompose: provider '{}' succeeded after trying: {}",
                            np.name,
                            tried.join(", ")
                        );
                    }
                    return Ok(resp);
                }
                Err(e) => {
                    attempts.push((np.name.clone(), format!("{e:#}")));
                }
            }
        }
        Err(anyhow::anyhow!("{}", Self::format_all_failed(&attempts)))
    }
}

/// Build the provider for `chump gap decompose` per the selected backend.
///
/// - [`DecomposeBackend::Cascade`] → the historical cascade, wrapped so a
///   failure still reports "providers tried: cascade".
/// - [`DecomposeBackend::Claude`] → `claude -p` only.
/// - [`DecomposeBackend::Auto`] → cascade first, then `claude -p`.
pub fn build_decompose_provider(
    backend: DecomposeBackend,
    model: Option<String>,
) -> Box<dyn Provider + Send + Sync> {
    let mut providers: Vec<NamedProvider> = Vec::new();
    match backend {
        DecomposeBackend::Cascade => {
            providers.push(NamedProvider {
                name: "cascade".into(),
                provider: crate::provider_cascade::build_provider(),
            });
        }
        DecomposeBackend::Claude => {
            providers.push(NamedProvider {
                name: "claude -p".into(),
                provider: Box::new(ClaudeCliProvider::new(model)),
            });
        }
        DecomposeBackend::Auto => {
            providers.push(NamedProvider {
                name: "cascade".into(),
                provider: crate::provider_cascade::build_provider(),
            });
            providers.push(NamedProvider {
                name: "claude -p".into(),
                provider: Box::new(ClaudeCliProvider::new(model)),
            });
        }
    }
    Box::new(FallthroughProvider::new(providers))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;

    /// A stub provider that either fails with a fixed error or succeeds with a
    /// fixed body, recording the order in which it was called.
    struct StubProvider {
        name: &'static str,
        succeed_with: Option<String>,
        fail_with: Option<String>,
        call_log: Arc<Vec<&'static str>>,
        counter: Arc<AtomicUsize>,
    }

    #[async_trait]
    impl Provider for StubProvider {
        async fn complete(
            &self,
            _messages: Vec<Message>,
            _tools: Option<Vec<Tool>>,
            _max_tokens: Option<u32>,
            _system_prompt: Option<String>,
        ) -> Result<CompletionResponse> {
            // Record call order via a shared counter (name captured in panic
            // message if assertions below need it).
            self.counter.fetch_add(1, Ordering::SeqCst);
            let _ = &self.call_log;
            if let Some(body) = &self.succeed_with {
                return Ok(CompletionResponse {
                    text: Some(body.clone()),
                    tool_calls: Vec::new(),
                    stop_reason: StopReason::EndTurn,
                });
            }
            let reason = self
                .fail_with
                .clone()
                .unwrap_or_else(|| format!("{} failed", self.name));
            anyhow::bail!("{reason}")
        }
    }

    fn mk(
        name: &'static str,
        succeed: Option<&str>,
        fail: Option<&str>,
        counter: Arc<AtomicUsize>,
    ) -> NamedProvider {
        NamedProvider {
            name: name.to_string(),
            provider: Box::new(StubProvider {
                name,
                succeed_with: succeed.map(|s| s.to_string()),
                fail_with: fail.map(|s| s.to_string()),
                call_log: Arc::new(Vec::new()),
                counter,
            }),
        }
    }

    #[tokio::test]
    async fn fallthrough_reaches_claude_when_cascade_down() {
        // cascade (Ollama) is down; claude stub succeeds — proves fallthrough.
        let counter = Arc::new(AtomicUsize::new(0));
        let fp = FallthroughProvider::new(vec![
            mk(
                "cascade",
                None,
                Some("model HTTP unreachable (daemon down)"),
                counter.clone(),
            ),
            mk(
                "claude -p",
                Some("[{\"title\":\"slice\"}]"),
                None,
                counter.clone(),
            ),
        ]);
        let resp = fp
            .complete(
                vec![Message {
                    role: "user".into(),
                    content: "decompose".into(),
                }],
                None,
                Some(4096),
                Some("sys".into()),
            )
            .await
            .expect("fallthrough should reach claude");
        assert_eq!(resp.text.as_deref(), Some("[{\"title\":\"slice\"}]"));
        // Both providers were attempted, cascade first.
        assert_eq!(counter.load(Ordering::SeqCst), 2);
    }

    #[tokio::test]
    async fn first_success_short_circuits() {
        let counter = Arc::new(AtomicUsize::new(0));
        let fp = FallthroughProvider::new(vec![
            mk("cascade", Some("[]"), None, counter.clone()),
            mk("claude -p", Some("[{}]"), None, counter.clone()),
        ]);
        let resp = fp
            .complete(vec![], None, None, None)
            .await
            .expect("cascade should win");
        assert_eq!(resp.text.as_deref(), Some("[]"));
        // Only the first provider was called.
        assert_eq!(counter.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn all_failed_lists_every_provider_in_order() {
        let counter = Arc::new(AtomicUsize::new(0));
        let fp = FallthroughProvider::new(vec![
            mk("cascade", None, Some("ollama unreachable"), counter.clone()),
            mk(
                "claude -p",
                None,
                Some("claude not on PATH"),
                counter.clone(),
            ),
        ]);
        let err = fp
            .complete(vec![], None, None, None)
            .await
            .expect_err("both fail");
        let msg = format!("{err:#}");
        assert!(msg.contains("tried in order"), "msg={msg}");
        assert!(msg.contains("1. cascade"), "msg={msg}");
        assert!(msg.contains("ollama unreachable"), "msg={msg}");
        assert!(msg.contains("2. claude -p"), "msg={msg}");
        assert!(msg.contains("claude not on PATH"), "msg={msg}");
        assert_eq!(counter.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn format_all_failed_numbers_in_order() {
        let out = FallthroughProvider::format_all_failed(&[
            ("cascade".into(), "down".into()),
            ("claude -p".into(), "no binary".into()),
        ]);
        let p1 = out.find("1. cascade").expect("cascade first");
        let p2 = out.find("2. claude -p").expect("claude second");
        assert!(p1 < p2, "cascade must be listed before claude: {out}");
    }

    #[test]
    fn backend_parse_flag() {
        assert_eq!(
            DecomposeBackend::parse_flag("auto").unwrap(),
            DecomposeBackend::Auto
        );
        assert_eq!(
            DecomposeBackend::parse_flag("Cascade").unwrap(),
            DecomposeBackend::Cascade
        );
        assert_eq!(
            DecomposeBackend::parse_flag("claude").unwrap(),
            DecomposeBackend::Claude
        );
        assert!(DecomposeBackend::parse_flag("bogus").is_err());
    }

    #[test]
    fn claude_prompt_includes_system_and_user() {
        let p = ClaudeCliProvider::build_prompt(
            &[Message {
                role: "user".into(),
                content: "decompose this".into(),
            }],
            Some("You are a PM assistant"),
        );
        assert!(p.contains("SYSTEM INSTRUCTIONS:"));
        assert!(p.contains("You are a PM assistant"));
        assert!(p.contains("USER:"));
        assert!(p.contains("decompose this"));
    }
}
