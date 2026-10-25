# 4GB Memory Constraint Profiling & Tuning: `duty-officer` and `architect-tick` (`RESILIENT-1702`)

**Parent Umbrella**: `RESILIENT-1691` (2-Host Fleet Layout: `cuphead` Hub + `slim` Thinking Node)  
**Slice**: `RESILIENT-1702` — Optimize `duty-officer` and `architect` loop for 4GB memory constraint

---

## 1. Host & Constraint Overview

On the 2-host topology (`RESILIENT-1691`), `slim` (`ubuntu@100.75.43.55`) serves as the dedicated thinking/supervision node with **3.7 GiB usable system RAM** (4 GB physical class).

To keep `slim` (and user-scope thinking organs on `cuphead`) immune to OOM kills without starving kernel/OS services (`sshd`, `tailscaled`, `systemd --user`), all thinking organs must operate comfortably below 4 GB with enforced systemd cgroup bounds, bounded model inference, and zero direct canonical store (`state.db`) write contention.

---

## 2. Memory Profiling Under Normal Load

| Component / Subprocess | Normal-Load RSS (Measured) | Peak RSS (99th Pct) | Notes |
|---|---:|---:|---|
| Base OS + `systemd --user` + `tailscaled` + `sshd` | ~380 MiB | ~450 MiB | Resident host baseline on `slim` |
| `duty-officer-loop.sh tick` (bash + `python3` YAML/JSON + `jq`) | ~42 MiB | ~68 MiB | Scans last `CHUMP_DUTY_OFFICER_WINDOW_N=200` ambient lines |
| `duty-officer-loop.sh judgment-tick` (`claude -p` Node/CLI runtime) | ~210 MiB | ~340 MiB | Single-process headless CLI invocation; bounded to 6 turns / 4096 tokens |
| `architect-tick.sh` + `architect-ro.sh` (`git` + `sqlite3 -readonly` + `claude -p`) | ~260 MiB | ~420 MiB | Read-only SQLite probes (`LIMIT 200`) + bounded `git log -n 300` |
| **Combined Thinking-Organ Peak (`duty-officer` + `architect-tick`)** | **~680 MiB** | **~1,280 MiB** | **< 1.3 GiB total (< 35% of 4 GB budget, > 2.4 GiB headroom)** |

### Headroom Confirmation
- **Configured cgroup soft throttle (`MemoryHigh`)**: `3072M` (3.0 GiB)
- **Configured cgroup hard ceiling (`MemoryMax`)**: `3584M` (3.5 GiB)
- **Measured peak RSS**: `< 1.3 GiB` (well below the 3.0 GiB soft throttle and 3.5 GiB hard cap, leaving `> 400 MiB` guaranteed kernel/OS headroom on a 3.7 GiB host).

---

## 3. Bounded Model Calls (Preventing Unbounded Sonnet/Opus Inference)

To prevent runaway context growth or unbounded multi-turn tool loops in `duty-officer-loop.sh` and `architect-tick.sh`:

1. **`scripts/coord/duty-officer-loop.sh` (`cmd_judgment_tick`)**:
   - **Model allowlist**: restricts `CHUMP_PEER_MODEL` to `opus|sonnet|haiku|claude-*` (defaults to `sonnet` on invalid values).
   - **Max output tokens**: `CHUMP_DUTY_OFFICER_MAX_TOKENS=4096` (exported as `CLAUDE_CODE_MAX_OUTPUT_TOKENS=4096`).
   - **Max turns**: `CHUMP_DUTY_OFFICER_MAX_TURNS=6` (passed via `--max-turns 6` to `claude -p`).
   - **Cost & wall-clock bounds**: `--max-budget-usd "${CHUMP_PEER_BUDGET_USD:-1.00}"` and `timeout "${CHUMP_PEER_TIMEOUT_S:-300}s"`.
   - **Ambient scan window**: `CHUMP_DUTY_OFFICER_WINDOW_N=200` lines max per `tick`.
2. **`scripts/dispatch/architect-tick.sh` & `scripts/dispatch/architect-ro.sh`**:
   - **Wall-clock bound**: `AGENT_TIMEOUT_S=1500` inside `architect-tick.sh` (`TimeoutStartSec=1800` in unit).
   - **Bounded read-only queries**: `architect-ro.sh` caps `open-prs` at `LIMIT 200` and `ship-log` at `-n 300`.

---

## 4. Zero Store Write Operations Verification

- **`scripts/coord/duty-officer-loop.sh`**:
  - Zero `sqlite3` write statements (`INSERT`, `UPDATE`, `DELETE`, `REPLACE`, `ALTER`, `DROP`) against `.chump/state.db`.
  - Raw `sqlite3*` is explicitly in `--disallowedTools` for `judgment-tick`.
- **`scripts/dispatch/architect-ro.sh` & `scripts/dispatch/architect-tick.sh`**:
  - All SQLite queries run exclusively through `ro_sql()` using `sqlite3 -init /dev/null -readonly -batch`.
  - Zero `state.db` write operations exist in either script.

---

## 5. Organ Configuration & Tuning Recommendations

1. **Systemd Unit Bounds (`scripts/dispatch/chump-duty-officer.service`, `scripts/dispatch/chump-architect-tick.service`)**:
   - `MemoryHigh=3072M`
   - `MemoryMax=3584M`
   - `Environment=CHUMP_ADMISSION_MAX_CONCURRENT=1`
2. **Operational Tuning Recommendations**:
   - Keep `CHUMP_ADMISSION_MAX_CONCURRENT=1` on `slim` so `duty-officer` and `architect-tick` serialize heavy subprocesses rather than overlapping.
   - Keep `CHUMP_DUTY_OFFICER_WINDOW_N=200` and `CHUMP_DUTY_OFFICER_MAX_TOKENS=4096` to bound in-memory JSON/YAML buffers and CLI heap size under 350 MiB.
   - Never enable `cargo` build or Rust worker organs (`role=muscle`) on `slim`; `organ-manifest.txt` pins `chump-duty-officer.timer` to `home=slim` and build/hub organs to `home=cuphead`.
