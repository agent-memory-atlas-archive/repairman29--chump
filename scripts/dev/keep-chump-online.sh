#!/usr/bin/env bash
# Keep Chump stack online: Ollama (11434), optional embed (18765), optional Discord bot.
# Farmer Brown calls this after diagnosing/killing stale processes.
#
# Env (optional, from .env):
#   CHUMP_KEEPALIVE_EMBED=1     Start embed server on CHUMP_EMBED_PORT (default 18765) if not up.
#   CHUMP_KEEPALIVE_DISCORD=1   Start Chump Discord if DISCORD_TOKEN set and not running.
#   CHUMP_KEEPALIVE_WORKER=1    Not used here; Farmer Brown handles worker port.
#   CHUMP_KEEPALIVE_INTERVAL=N  If set, loop every N seconds; otherwise run once.
#
# Logs: logs/keep-chump-online.log

set -e
ROOT="${CHUMP_HOME:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$ROOT"
export PATH="${HOME}/.local/bin:${HOME}/.cursor/bin:${PATH}"
if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

LOG="$ROOT/logs/keep-chump-online.log"
mkdir -p "$ROOT/logs"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOG"; }

# Local vLLM-MLX on 8000 or 8001 (from OPENAI_API_BASE) => no Ollama, no embed (in-process embed with Chump).
# In-process mistral.rs primary => do not start Ollama or vLLM-MLX (same LLM stack as Chump binary).
USE_OLLAMA=1
USE_EMBED=1
USE_LOCAL_MLX=0
LOCAL_MLX_PORT=""
if [[ -x "$ROOT/scripts/setup/inference-primary-mistralrs.sh" ]] && "$ROOT/scripts/setup/inference-primary-mistralrs.sh" 2>/dev/null; then
  USE_OLLAMA=0
  USE_EMBED=0
  USE_LOCAL_MLX=0
  log "mistral.rs in-process primary: not starting Ollama or vLLM-MLX (avoid competing LLMs)."
else
  LOCAL_MLX_PORT="$("$ROOT/scripts/setup/openai-base-local-mlx-port.sh" 2>/dev/null || true)"
  if [[ "$LOCAL_MLX_PORT" == "8000" || "$LOCAL_MLX_PORT" == "8001" ]]; then
    USE_OLLAMA=0
    USE_EMBED=0
    USE_LOCAL_MLX=1
    log "Local MLX config (port ${LOCAL_MLX_PORT}): skipping Ollama and embed; will keep vLLM-MLX up."
  fi
fi

vllm_local_mlx_ready() {
  [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${LOCAL_MLX_PORT}/v1/models" 2>/dev/null)" == "200" ]]
}

if [[ "$USE_LOCAL_MLX" == "1" ]]; then
  if [[ -x "$ROOT/scripts/setup/stop-ollama-if-running.sh" ]]; then
    bash "$ROOT/scripts/setup/stop-ollama-if-running.sh" || true
  fi
  if vllm_local_mlx_ready; then
    log "vLLM-MLX (${LOCAL_MLX_PORT}) already up."
  else
    log "vLLM-MLX (${LOCAL_MLX_PORT}) not ready; starting..."
    if [[ "$LOCAL_MLX_PORT" == "8000" ]] && [[ -x "$ROOT/scripts/setup/restart-vllm-if-down.sh" ]]; then
      "$ROOT/scripts/setup/restart-vllm-if-down.sh" >>"$LOG" 2>&1 || true
    elif [[ "$LOCAL_MLX_PORT" == "8001" ]] && [[ -x "$ROOT/scripts/setup/restart-vllm-8001-if-down.sh" ]]; then
      "$ROOT/scripts/setup/restart-vllm-8001-if-down.sh" >>"$LOG" 2>&1 || true
    elif [[ "$LOCAL_MLX_PORT" == "8000" ]]; then
      nohup "$ROOT/serve-vllm-mlx.sh" >>"$ROOT/logs/vllm-mlx-8000.log" 2>&1 &
      log "vLLM (8000) start triggered (logs: logs/vllm-mlx-8000.log)."
    else
      nohup env PORT=8001 "$ROOT/scripts/setup/serve-vllm-mlx-8001.sh" >>"$ROOT/logs/vllm-mlx-8001.log" 2>&1 &
      log "vLLM (8001) start triggered (logs: logs/vllm-mlx-8001.log)."
    fi
    sleep 5
    if vllm_local_mlx_ready; then
      log "vLLM-MLX (${LOCAL_MLX_PORT}) started."
    else
      log "vLLM-MLX (${LOCAL_MLX_PORT}) may still be loading; check logs/vllm-mlx-${LOCAL_MLX_PORT}.log"
    fi
  fi
fi

# --- Ollama (11434) ---
ollama_ready() {
  curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:11434/api/tags" 2>/dev/null || true
}

# RESILIENT-1502: nodes that route their fleet workers through a working
# backend (headless claude / free-tier cascade — see FLEET_BACKEND default in
# scripts/dispatch/worker.sh) never install Ollama. Without this guard the
# "Starting Ollama..." branch below still fires `nohup ollama serve` every
# time this script runs (farmer-brown calls it in a loop), which fails
# instantly with "nohup: failed to run command 'ollama': No such file or
# directory" and spams logs/ollama-serve.log forever instead of surfacing a
# single actionable health error.
if [[ "$USE_OLLAMA" == "1" ]] && ! command -v ollama >/dev/null 2>&1; then
  log "HEALTH ERROR: USE_OLLAMA=1 but 'ollama' binary is not installed on this host — skipping Ollama startup (not retrying). Install ollama, or route this node's fleet workers through FLEET_BACKEND=claude / a configured CHUMP_FREE_TIER_PROVIDERS cascade instead."
  USE_OLLAMA=0
fi

if [[ "$USE_OLLAMA" == "1" ]]; then
  if [[ "$(ollama_ready)" != "200" ]]; then
    log "Starting Ollama..."
    nohup ollama serve >> "$ROOT/logs/ollama-serve.log" 2>&1 &
    echo $! >> "$LOG"
    for i in $(seq 1 40); do
      [[ "$(ollama_ready)" == "200" ]] && break
      sleep 3
    done
    if [[ "$(ollama_ready)" == "200" ]]; then
      log "Ollama ready on 11434."
    else
      log "Ollama failed to become ready; check logs/ollama-serve.log"
    fi
  else
    log "Ollama already up (11434)."
  fi
fi

# --- Embed (optional) ---
if [[ "$USE_EMBED" == "1" ]] && [[ "${CHUMP_KEEPALIVE_EMBED:-0}" == "1" ]]; then
  EMBED_PORT="${CHUMP_EMBED_PORT:-18765}"
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:${EMBED_PORT}/" 2>/dev/null || echo "000")
  if [[ "$code" != "200" ]] && [[ "$code" != "404" ]] && [[ "$code" != "405" ]]; then
    log "Starting embed server on ${EMBED_PORT}..."
    if [[ -x "$ROOT/scripts/setup/start-embed-server.sh" ]]; then
      nohup "$ROOT/scripts/setup/start-embed-server.sh" >> "$ROOT/logs/embed-server.log" 2>&1 &
      sleep 5
    else
      log "start-embed-server.sh not found or not executable; skipping embed."
    fi
  else
    log "Embed already up (${EMBED_PORT})."
  fi
fi

# --- Chump Discord (optional; default on in max mode so stack stays up) ---
[[ "$USE_LOCAL_MLX" == "1" ]] && [[ -z "${CHUMP_KEEPALIVE_DISCORD:-}" ]] && CHUMP_KEEPALIVE_DISCORD=1
if [[ "${CHUMP_KEEPALIVE_DISCORD:-0}" == "1" ]] && [[ -n "${DISCORD_TOKEN:-}" ]]; then
  if pgrep -f "chump.*--discord" >/dev/null 2>&1 || pgrep -f "rust-agent.*--discord" >/dev/null 2>&1; then
    log "Chump Discord already running."
  else
    log "Starting Chump Discord..."
    if [[ "$USE_LOCAL_MLX" == "1" ]] && [[ -x "$ROOT/run-discord-full.sh" ]]; then
      nohup "$ROOT/run-discord-full.sh" >> "$ROOT/logs/discord.log" 2>&1 &
    else
      nohup "$ROOT/run-discord.sh" >> "$ROOT/logs/discord.log" 2>&1 &
    fi
    log "Chump Discord started (logs: logs/discord.log)."
  fi
else
  if [[ "${CHUMP_KEEPALIVE_DISCORD:-0}" == "1" ]] && [[ -z "${DISCORD_TOKEN:-}" ]]; then
    log "CHUMP_KEEPALIVE_DISCORD=1 but DISCORD_TOKEN not set; skipping Discord."
  fi
fi

# --- Optional loop ---
INTERVAL="${CHUMP_KEEPALIVE_INTERVAL:-}"
if [[ -n "$INTERVAL" ]] && [[ "$INTERVAL" -gt 0 ]]; then
  log "Looping every ${INTERVAL}s (Ctrl+C to stop)."
  while true; do
    sleep "$INTERVAL"
    log "=== Next pass ==="
    # vLLM-MLX (8000 or 8001)
    if [[ "$USE_LOCAL_MLX" == "1" ]] && ! vllm_local_mlx_ready; then
      log "vLLM-MLX (${LOCAL_MLX_PORT}) down; starting..."
      if [[ "$LOCAL_MLX_PORT" == "8000" ]]; then
        [[ -x "$ROOT/scripts/setup/restart-vllm-if-down.sh" ]] && "$ROOT/scripts/setup/restart-vllm-if-down.sh" >>"$LOG" 2>&1 || true
      else
        [[ -x "$ROOT/scripts/setup/restart-vllm-8001-if-down.sh" ]] && "$ROOT/scripts/setup/restart-vllm-8001-if-down.sh" >>"$LOG" 2>&1 || true
      fi
    fi
    # Ollama (skip when local MLX)
    if [[ "$USE_OLLAMA" == "1" ]] && [[ "$(ollama_ready)" != "200" ]]; then
      log "Ollama down; starting..."
      nohup ollama serve >> "$ROOT/logs/ollama-serve.log" 2>&1 &
    fi
    # Embed (skip when local MLX)
    if [[ "$USE_EMBED" == "1" ]] && [[ "${CHUMP_KEEPALIVE_EMBED:-0}" == "1" ]]; then
      EMBED_PORT="${CHUMP_EMBED_PORT:-18765}"
      code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:${EMBED_PORT}/" 2>/dev/null || echo "000")
      if [[ "$code" != "200" ]] && [[ "$code" != "404" ]] && [[ "$code" != "405" ]]; then
        [[ -x "$ROOT/scripts/setup/start-embed-server.sh" ]] && nohup "$ROOT/scripts/setup/start-embed-server.sh" >> "$ROOT/logs/embed-server.log" 2>&1 &
      fi
    fi
    # Discord
    if [[ "${CHUMP_KEEPALIVE_DISCORD:-0}" == "1" ]] && [[ -n "${DISCORD_TOKEN:-}" ]]; then
      if ! pgrep -f "chump.*--discord" >/dev/null 2>&1 && ! pgrep -f "rust-agent.*--discord" >/dev/null 2>&1; then
        log "Chump Discord down; starting..."
        if [[ "$USE_LOCAL_MLX" == "1" ]] && [[ -x "$ROOT/run-discord-full.sh" ]]; then
          nohup "$ROOT/run-discord-full.sh" >> "$ROOT/logs/discord.log" 2>&1 &
        else
          nohup "$ROOT/run-discord.sh" >> "$ROOT/logs/discord.log" 2>&1 &
        fi
      fi
    fi
  done
fi

log "keep-chump-online pass done."
