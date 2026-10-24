#!/usr/bin/env bash
# auth-status.sh — RESILIENT-086: the canonical fleet-auth VALIDITY check.
#
# WHY THIS EXISTS: every new agent re-pays the same tax. The fleet can hold a
# valid oauth (subscription) token AND a depleted/invalid api-key at the same
# time — and because `claude -p` prefers ANTHROPIC_API_KEY in auto mode, the
# DEPLETED key silently wins precedence over the VALID oauth, so workers fail
# while every presence-only check (farmer, `fleet doctor`) reports "auth set".
# Presence != validity (RESILIENT-086). This probes the ACTUAL working path
# with a real call and prints ONE unambiguous line, so no agent re-diagnoses.
#
# It specifically catches the PRECEDENCE TRAP: "the credential claude -p would
# use is broken, but a different one is valid" — the #1 recurring confusion.
#
# Exit 0 = a usable auth path exists (workers can transact).
# Exit 1 = no usable auth path (prints the exact fix).
# Exit 2 = usable, but the precedence-winner is broken (prints the exact fix).
#
# Usage: auth-status.sh [--probe] [--quiet]
#   default : use cached verdict if < CHUMP_AUTH_STATUS_TTL_S old, else probe.
#   --probe : force a fresh probe.   --quiet: print only the one-line verdict.

set -uo pipefail
REPO_ROOT="${CHUMP_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)}"
CACHE="${CHUMP_AUTH_STATUS_CACHE:-$HOME/.chump/auth-status-cache}"
TTL="${CHUMP_AUTH_STATUS_TTL_S:-600}"
FORCE=0; QUIET=0
# --force/-f are intuitive aliases of --probe (CREDIBLE-146: operators reached
# for --force to bust a stale verdict; it silently fell through and served cache).
for a in "$@"; do case "$a" in --probe|--force|-f) FORCE=1 ;; --quiet|-q) QUIET=1 ;; esac; done

_now() { date +%s; }

# ── cache: at most one real probe per TTL window ─────────────────────────────
# CREDIBLE-146 hardening — a stale/bad cache silently froze the fleet for days
# (a cached BROKEN kept the farmer paging AUTH_DEAD while the credential was
# valid). Three rules so that can't recur:
#   (a) NEVER serve a cached BROKEN/TRAP verdict — any non-zero rc is re-probed
#       fresh, so a valid credential is never masked by a stale failure;
#   (b) auto-invalidate when a credential source (oauth token or .env) is newer
#       than the cache — a just-refreshed token busts the stale verdict;
#   (c) --force/-f (aliases of --probe, above) skip the cache entirely.
if [[ "$FORCE" -eq 0 && -f "$CACHE" ]]; then
    _c_ts="$(sed -n '1p' "$CACHE" 2>/dev/null || echo 0)"
    _c_rc="$(sed -n '2p' "$CACHE" 2>/dev/null || echo 1)"
    _c_msg="$(sed -n '3,$p' "$CACHE" 2>/dev/null)"
    # (b) any credential file newer than the cache invalidates the cached verdict.
    _cred_fresh=0
    for _cred in "$HOME/.chump/oauth-token.json" "$REPO_ROOT/.env"; do
        [ -f "$_cred" ] && [ "$_cred" -nt "$CACHE" ] && _cred_fresh=1
    done
    if [[ "$_c_ts" =~ ^[0-9]+$ ]] \
       && [ "$_c_rc" -eq 0 ] \
       && [ "$_cred_fresh" -eq 0 ] \
       && [ $(( $(_now) - _c_ts )) -lt "$TTL" ]; then
        [ "$QUIET" -eq 0 ] && printf '%s (cached)\n' "$_c_msg" || printf '%s\n' "$_c_msg"
        exit "$_c_rc"
    fi
fi

# ── resolve credentials as the WORKERS see them ──────────────────────────────
# launchd-spawned workers inherit the launchctl global env (macOS), so prefer
# launchctl over THIS shell's (possibly stale/personal) env — that very mismatch
# is a recurring source of "it works for me but not the fleet" confusion.
_lc() { command -v launchctl >/dev/null 2>&1 && launchctl getenv "$1" 2>/dev/null || true; }
_auth_mode="$(_lc CHUMP_AUTH_MODE)"; _auth_mode="${_auth_mode:-${CHUMP_AUTH_MODE:-auto}}"
_api_key="$(_lc ANTHROPIC_API_KEY)"; _api_key="${_api_key:-${ANTHROPIC_API_KEY:-}}"
if [[ -z "$_api_key" && -f "$REPO_ROOT/.env" ]]; then
    _api_key="$(grep -E '^ANTHROPIC_API_KEY=' "$REPO_ROOT/.env" 2>/dev/null | head -1 \
                | cut -d= -f2- | sed 's/^"//;s/"$//;s/^'"'"'//;s/'"'"'$//')"
fi
_oauth_tok="$(_lc CLAUDE_CODE_OAUTH_TOKEN)"; _oauth_tok="${_oauth_tok:-${CLAUDE_CODE_OAUTH_TOKEN:-}}"
if [[ -z "$_oauth_tok" && -f "$HOME/.chump/oauth-token.json" ]]; then
    _oauth_tok="$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.chump/oauth-token.json'))).get('token',''))" 2>/dev/null || true)"
fi

# ── free-tier provider path (RESILIENT-376) ──────────────────────────────────
# A node configured for a $0 / free-tier OpenAI-compatible provider needs NO
# Anthropic credential to transact: `chump --execute-gap` drives the in-process
# cascade (OPENAI_API_BASE/OPENAI_API_KEY/OPENAI_MODEL), never `claude`. On such
# a node the `claude -p` probe below is a false BROKEN — the Android Pixel node
# has no `claude` native binary at all, so it RED-locks a $0 worker that needs
# zero Anthropic creds. Treat a LIVE free-tier provider as a usable auth path.
#
# BLAST-RADIUS GUARD (non-negotiable): this block is ENTIRELY skipped when
# CHUMP_FREE_TIER_PROVIDERS is empty/unset — i.e. on every Claude node (CJ, the
# Mac, helsinki). Their verdict, cache, and exit code are byte-for-byte
# unchanged. A live provider only ever ADDS a usable path; a dead/misconfigured
# one FALLS THROUGH to the unchanged Anthropic probe below (never a wrong-GREEN).
#
# Entry format matches src/execute_gap.rs::parse_free_tier_providers:
#   model@base_url:KEY_ENV   (comma-separated). We resolve KEY_ENV indirectly and
# probe ${base_url}/models with a Bearer key; first HTTP 200 → usable → exit 0.
# We iterate the whole list so an OpenAI-compatible entry (Groq/Cerebras/…)
# satisfies the gate even when another entry's base (e.g. Gemini's
# generativelanguage) won't answer a Bearer /models probe.
_ft_providers="${CHUMP_FREE_TIER_PROVIDERS:-}"
if [[ -z "${_ft_providers//[[:space:]]/}" && "${CHUMP_BYOK_PRIMARY:-0}" == "1" ]]; then
    # RESILIENT-1688: Synthesize probe targets on BYOK-primary nodes when
    # CHUMP_FREE_TIER_PROVIDERS was not explicitly set.
    _ft_providers="gemini-3.8-flash@https://generativelanguage.googleapis.com/v1beta/openai:GEMINI_API_KEY,gemini-3.8-flash@https://generativelanguage.googleapis.com/v1beta/openai:GOOGLE_API_KEY,codestral-latest@https://api.mistral.ai/v1:MISTRAL_API_KEY,gpt-4o@https://api.openai.com/v1:OPENAI_API_KEY,qwen/qwen3-coder@https://openrouter.ai/api/v1:OPENROUTER_API_KEY"
fi
if [[ -n "${_ft_providers//[[:space:]]/}" ]]; then
    _ft_ok=0; _ft_model=""; _ft_host=""
    _ft_oldifs="$IFS"; IFS=','
    for _ft_entry in $_ft_providers; do
        IFS="$_ft_oldifs"
        _ft_entry="${_ft_entry#"${_ft_entry%%[![:space:]]*}"}"   # ltrim
        _ft_entry="${_ft_entry%"${_ft_entry##*[![:space:]]}"}"   # rtrim
        [ -z "$_ft_entry" ] && { IFS=','; continue; }
        # split on LAST ':' → KEY_ENV, then '@' → model / base_url
        _ft_key_env="${_ft_entry##*:}"
        _ft_model_base="${_ft_entry%:*}"
        _ft_model="${_ft_model_base%@*}"
        _ft_base="${_ft_model_base#*@}"
        if [[ -z "$_ft_model" || -z "$_ft_base" || -z "$_ft_key_env" || "$_ft_model_base" != *@* ]]; then
            IFS=','; continue
        fi
        _ft_key_val="${!_ft_key_env:-}"           # indirect: value of the named env var
        [ -z "$_ft_key_val" ] && { IFS=','; continue; }   # empty key (e.g. NVIDIA) → skip, never false-GREEN
        if [[ -n "${CHUMP_AUTH_STATUS_FAKE_FREETIER_HTTP:-}" ]]; then
            _ft_code="$CHUMP_AUTH_STATUS_FAKE_FREETIER_HTTP"   # CI seam: hermetic, no network
        else
            _ft_code="$(curl -s -o /dev/null -w '%{http_code}' \
                --max-time "${CHUMP_AUTH_FREETIER_PROBE_TIMEOUT_S:-10}" \
                -H "Authorization: Bearer $_ft_key_val" \
                "${_ft_base%/}/models" 2>/dev/null || echo 000)"
        fi
        if [[ "$_ft_code" == "200" ]]; then
            _ft_ok=1; _ft_model="$_ft_model"
            _ft_host="${_ft_base#*://}"; _ft_host="${_ft_host%%/*}"
            break
        fi
        IFS=','
    done
    IFS="$_ft_oldifs"
    if [[ "$_ft_ok" -eq 1 ]]; then
        RC=0
        MSG="AUTH ✓ OK — free-tier provider live ($_ft_model @ $_ft_host); no Anthropic token needed (chump --execute-gap cascade)."
        mkdir -p "$(dirname "$CACHE")" 2>/dev/null || true
        { _now; printf '%s\n' "$RC"; printf '%s\n' "$MSG"; } > "$CACHE" 2>/dev/null || true
        printf '%s\n' "$MSG"
        exit "$RC"
    fi
    # No live free-tier provider — fall through to the Anthropic probe (unchanged).
fi

# ── probe oauth (real claude -p call) ────────────────────────────────────────
# valid | invalid | absent
_oauth_state="absent"
if [[ -n "$_oauth_tok" && -z "${CHUMP_AUTH_STATUS_FAKE_OAUTH:-}" ]] && command -v claude >/dev/null 2>&1; then
    if (cd /tmp && CLAUDE_CODE_OAUTH_TOKEN="$_oauth_tok" ANTHROPIC_API_KEY= \
            timeout "${CHUMP_AUTH_PROBE_TIMEOUT_S:-60}" claude -p "Reply with exactly: PONG" \
            --model haiku 2>/dev/null | grep -q PONG); then
        _oauth_state="valid"
    else
        _oauth_state="invalid"
    fi
fi

# ── probe api-key (cheap REST call: distinguishes valid / depleted / invalid /
#    rate_limited / network_error) ────────────────────────────────────────────
# CREDIBLE-449 (INFRA-621 probe slice): classify the Anthropic API response
# body + HTTP status into a specific failure class instead of collapsing
# everything non-2xx/non-401/403 into "unknown" — a depleted credit balance
# (400 + "credit balance" in body), an invalid key (401/403), a rate limit
# (429), and a network-layer failure (curl couldn't even reach the server,
# code 000) each need a DIFFERENT fix and must not be confused for each other.
_apikey_state="absent"
if [[ -n "$_api_key" && -z "${CHUMP_AUTH_STATUS_FAKE_APIKEY:-}" ]]; then
    _tmp="$(mktemp -t authprobe.XXXXXX)"
    _code="$(curl -s -o "$_tmp" -w '%{http_code}' https://api.anthropic.com/v1/messages \
        -H "x-api-key: $_api_key" -H "anthropic-version: 2023-06-01" -H "content-type: application/json" \
        -d '{"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}' \
        2>/dev/null || echo 000)"
    _body="$(cat "$_tmp" 2>/dev/null)"; rm -f "$_tmp"
    case "$_code" in
        200) _apikey_state="valid" ;;
        400) if grep -qi 'credit balance' <<<"$_body"; then _apikey_state="depleted"; else _apikey_state="valid"; fi ;;
        401|403) _apikey_state="invalid" ;;
        429) _apikey_state="rate_limited" ;;
        000) _apikey_state="network_error" ;;
        *) _apikey_state="unknown" ;;
    esac
fi

# ── test injection (CI only) — override probe results to exercise verdict logic ─
[[ -n "${CHUMP_AUTH_STATUS_FAKE_OAUTH:-}" ]]  && _oauth_state="$CHUMP_AUTH_STATUS_FAKE_OAUTH"
[[ -n "${CHUMP_AUTH_STATUS_FAKE_APIKEY:-}" ]] && _apikey_state="$CHUMP_AUTH_STATUS_FAKE_APIKEY"
[[ -n "${CHUMP_AUTH_STATUS_FAKE_MODE:-}" ]]   && _auth_mode="$CHUMP_AUTH_STATUS_FAKE_MODE"

# ── which path would `claude -p` actually use? (precedence model) ────────────
# auto: api-key wins if present; else oauth.   oauth: oauth.   api-key: api-key.
case "$_auth_mode" in
    api-key) _effective="api-key" ;;
    oauth)   _effective="oauth" ;;
    *)       if [[ "$_apikey_state" != "absent" ]]; then _effective="api-key"; else _effective="oauth"; fi ;;
esac
_eff_state="$_apikey_state"; [[ "$_effective" == "oauth" ]] && _eff_state="$_oauth_state"

# ── verdict ──────────────────────────────────────────────────────────────────
RC=1; MSG=""
if [[ "$_eff_state" == "valid" ]]; then
    RC=0; MSG="AUTH ✓ OK — $_effective validated (mode=$_auth_mode); workers can transact."
elif [[ "$_oauth_state" == "valid" || "$_apikey_state" == "valid" ]]; then
    # A valid path EXISTS but the precedence-winner is broken — THE TRAP.
    _good="oauth"; [[ "$_apikey_state" == "valid" ]] && _good="api-key"
    RC=2
    if [[ "$_effective" == "api-key" && "$_good" == "oauth" ]]; then
        MSG="AUTH ⚠ TRAP — api-key is $_apikey_state but oauth is VALID, and claude -p prefers the api-key, so workers FAIL. FIX: retire the api-key for the fleet → 'launchctl unsetenv ANTHROPIC_API_KEY' + comment ANTHROPIC_API_KEY in .env (oauth then wins)."
    else
        MSG="AUTH ⚠ TRAP — $_effective is $_eff_state but $_good is VALID. FIX: set CHUMP_AUTH_MODE=$_good (or remove the broken credential) so claude -p uses the working path."
    fi
else
    RC=1
    if [[ "$_apikey_state" == "depleted" ]]; then
        MSG="AUTH ✗ BROKEN — api-key OUT OF CREDITS and oauth $_oauth_state. FIX: add credits at console.anthropic.com/settings/billing, OR run 'claude setup-token' and ensure ~/.chump/oauth-token.json holds it (then CHUMP_AUTH_MODE=oauth)."
    elif [[ "$_apikey_state" == "rate_limited" && "$_oauth_state" != "valid" ]]; then
        MSG="AUTH ✗ BROKEN — api-key RATE LIMITED (429, transient) and oauth $_oauth_state. FIX: retry shortly (do not rotate credentials for a rate limit), or run 'claude setup-token' for an oauth fallback."
    elif [[ "$_apikey_state" == "network_error" && "$_oauth_state" != "valid" ]]; then
        MSG="AUTH ✗ BROKEN — api-key probe hit a NETWORK ERROR (couldn't reach api.anthropic.com) and oauth $_oauth_state. FIX: check network/DNS/proxy; this is not a credential problem — re-probe with 'auth-status.sh --probe' once connectivity is restored."
    elif [[ "$_oauth_state" == "absent" && "$_apikey_state" == "absent" ]]; then
        MSG="AUTH ✗ BROKEN — no credentials found. FIX: run 'claude setup-token' (subscription oauth) → save to ~/.chump/oauth-token.json, OR set ANTHROPIC_API_KEY."
    else
        MSG="AUTH ✗ BROKEN — oauth=$_oauth_state api-key=$_apikey_state, none usable. FIX: 'claude setup-token' for a fresh oauth token, or provide a funded ANTHROPIC_API_KEY."
    fi
fi

# ── cache + emit ──────────────────────────────────────────────────────────────
mkdir -p "$(dirname "$CACHE")" 2>/dev/null || true
{ _now; printf '%s\n' "$RC"; printf '%s\n' "$MSG"; } > "$CACHE" 2>/dev/null || true
printf '%s\n' "$MSG"
exit "$RC"
