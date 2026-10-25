#!/usr/bin/env bash
# scripts/dispatch/lib/decompose-provider.sh
#
# Shared decompose/enrichment PROVIDER SELECTOR for gap-drain.sh + worker.sh.
#
# WHY THIS EXISTS
# --------------
# The decompose + gap-drain enrichment path pins OpenRouter deepseek-v4-pro as
# ProviderCascade slot 0 (a real planner, not the contended local ollama 3B).
# But OpenRouter is a PAID balance: when its credits run dry it returns HTTP 402
# on FULL-size requests — literally "This request requires more credits ... you
# requested up to N tokens, but can only afford M" — so decompose + enrich go
# DEAD while the cheap DeepSeek FLOOR (which runs on the Claude sub, not
# OpenRouter) keeps running fine. A dead decompose path silently stops slicing
# big gaps into landable ones.
#
# Per fleet doctrine "exhaust the free stack, don't satisfice": rather than
# requiring a paid top-up, fall to a CAPABLE FREE-TIER model when OpenRouter
# can't afford the call. Never fall to the local llama3.2:3b — that is the same
# 3B model the gaps already defeated (EFFECTIVE-512); a silent fall to it is a
# regression, so degradation here is LOUD.
#
# CASCADE
#   0. OpenRouter deepseek-v4-pro           (preferred quality) — used when a
#      decompose-size request is AFFORDABLE (affordability preflight below).
#   1. Google  gemini-3.6-flash             (free, generous TPM) — primary free.
#   2. Groq    openai/gpt-oss-120b          (free, 8k TPM cap)   — backup free.
#
# CONTROL SURFACE: exports OPENAI_API_BASE / OPENAI_API_KEY / OPENAI_MODEL — the
# three vars ProviderCascade reads (src/provider_cascade.rs:215 / 611 / 2099).
# Idempotent and subshell-safe (worker.sh calls it inside a scoped subshell).
#
# TUNING (env)
#   CHUMP_DRAIN_MODEL           OpenRouter model            (deepseek/deepseek-v4-pro)
#   CHUMP_DRAIN_AFFORD_TOKENS   affordability probe budget  (4096)
#   CHUMP_DRAIN_FREE_PROVIDER   free-tier order             ("google groq")
#   CHUMP_DRAIN_GOOGLE_MODEL    google model                (gemini-3.6-flash)
#   CHUMP_DRAIN_GROQ_MODEL      groq model                  (openai/gpt-oss-120b)
#   CHUMP_DECOMPOSE_API_BASE/_API_KEY/_MODEL   full manual override (escape hatch)

# pick_decompose_provider: select + export OPENAI_* for the decompose/enrich call.
pick_decompose_provider() {
  # Keys live in providers.env / cj.env. Source if none are loaded yet (callers
  # usually source already; this makes the helper self-sufficient in a subshell).
  if [ -z "${OPENROUTER_API_KEY:-}${GROQ_API_KEY:-}${GOOGLE_API_KEY:-}" ]; then
    local _dp_dir
    _dp_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    [ -f "$_dp_dir/load-provider-auth.env" ] && source "$_dp_dir/load-provider-auth.env" "$HOME/.chump/providers.env" "$HOME/.chump/cj.env" 2>/dev/null
  fi

  local drain_model="${CHUMP_DRAIN_MODEL:-deepseek/deepseek-v4-pro}"
  local afford_tokens="${CHUMP_DRAIN_AFFORD_TOKENS:-4096}"
  local or_base="https://openrouter.ai/api/v1"

  _dp_log() {  # $1 = message; echoes to stderr + ambient log (best-effort)
    echo "[decompose-provider] $1" >&2
    local al="${CHUMP_AMBIENT_LOG:-${REPO_ROOT:-$PWD}/.chump-locks/ambient.jsonl}"
    printf '{"ts":"%s","kind":"decompose_provider_selected","source":"decompose-provider.sh","detail":"%s"}\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$al" 2>/dev/null || true
  }

  # Full manual override escape hatch.
  if [ -n "${CHUMP_DECOMPOSE_API_BASE:-}" ]; then
    export OPENAI_API_BASE="$CHUMP_DECOMPOSE_API_BASE"
    export OPENAI_API_KEY="${CHUMP_DECOMPOSE_API_KEY:-${OPENAI_API_KEY:-}}"
    export OPENAI_MODEL="${CHUMP_DECOMPOSE_MODEL:-${OPENAI_MODEL:-}}"
    _dp_log "override base=$OPENAI_API_BASE model=$OPENAI_MODEL"
    return 0
  fi

  # 1) Prefer OpenRouter deepseek-v4-pro WHEN it can afford a decompose-size call.
  #    The preflight replicates the exact gate the real call hits: a
  #    max_tokens=<afford_tokens> reservation. A trivial "ok" prompt stops after
  #    a couple tokens, so the probe is ~free when it PASSES; when credits are
  #    dry OpenRouter 402s here just as the real decompose would.
  if [ -n "${OPENROUTER_API_KEY:-}" ]; then
    local code
    code=$(curl -sS -m 20 -o /dev/null -w "%{http_code}" "$or_base/chat/completions" \
      -H "Authorization: Bearer $OPENROUTER_API_KEY" -H "Content-Type: application/json" \
      -d "{\"model\":\"$drain_model\",\"messages\":[{\"role\":\"user\",\"content\":\"ok\"}],\"max_tokens\":$afford_tokens}" \
      2>/dev/null || echo "000")
    if [ "$code" = "200" ]; then
      export OPENAI_API_BASE="$or_base"
      export OPENAI_API_KEY="$OPENROUTER_API_KEY"
      export OPENAI_MODEL="$drain_model"
      _dp_log "openrouter affordable (http=$code) model=$drain_model"
      return 0
    fi
    _dp_log "openrouter unaffordable/unhealthy (http=$code) — falling to free tier"
  fi

  # 2) Free-tier cascade. First candidate whose key is set AND passes a tiny
  #    health ping wins. Capable models only — never the local 3B.
  local prefer="${CHUMP_DRAIN_FREE_PROVIDER:-google groq}"
  local p base model key hc
  for p in $prefer; do
    case "$p" in
      google)
        base="https://generativelanguage.googleapis.com/v1beta/openai"
        model="${CHUMP_DRAIN_GOOGLE_MODEL:-gemini-3.6-flash}"
        key="${GOOGLE_API_KEY:-}" ;;
      groq)
        base="https://api.groq.com/openai/v1"
        model="${CHUMP_DRAIN_GROQ_MODEL:-openai/gpt-oss-120b}"
        key="${GROQ_API_KEY:-}" ;;
      *) continue ;;
    esac
    [ -n "$key" ] || continue
    hc=$(curl -sS -m 15 -o /dev/null -w "%{http_code}" "$base/chat/completions" \
      -H "Authorization: Bearer $key" -H "Content-Type: application/json" \
      -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"ok\"}],\"max_tokens\":5}" \
      2>/dev/null || echo "000")
    if [ "$hc" = "200" ]; then
      export OPENAI_API_BASE="$base"
      export OPENAI_API_KEY="$key"
      export OPENAI_MODEL="$model"
      _dp_log "free-tier selected provider=$p model=$model (http=$hc)"
      return 0
    fi
    _dp_log "free-tier $p unhealthy (http=$hc) — trying next"
  done

  # 3) Nothing usable. Keep the OpenRouter pin (it will 402) and degrade LOUDLY —
  #    never a silent fall to the local llama3.2:3b. This is the genuine
  #    "top up OpenRouter" signal.
  if [ -n "${OPENROUTER_API_KEY:-}" ]; then
    export OPENAI_API_BASE="$or_base"
    export OPENAI_API_KEY="$OPENROUTER_API_KEY"
    export OPENAI_MODEL="$drain_model"
    _dp_log "WARN no free-tier usable and OpenRouter exhausted — pinning OpenRouter (will 402). Top up OpenRouter credits."
  else
    _dp_log "WARN no decompose provider available (no OpenRouter/Google/Groq keys)."
  fi
  return 0
}
