# PHASE-R R6 node observation (INFRA-8590 / INFRA-8195 AC3)

**Window:** START 2026-10-25T21:05Z — END 2026-10-26T21:05Z (24h), cuphead.
**Prereqs:** INFRA-8575 (#5596), INFRA-8582 (chumpd installed beside chump), INFRA-8583 (shared pause detector), INFRA-8588 (operator started worker service, option c). `chumpd worker` pid 923368 running at window start.

**Result: PASS** — INFRA-8195 AC3 satisfied.

## Probes

Hourly, per the gap's prescribed commands:

- `pgrep -fa 'chumpd worker'` — chumpd worker process present for the full window.
- `pgrep -fa 'worker.sh'` — only appeared as `--tick` single-tick bodies spawned by chumpd worker (e.g. `bash scripts/dispatch/worker.sh --tick`), never as a persistent inline loop. This is the expected shim-exec pattern, not a legacy standalone loop.
- `grep kind=worker_loop_backend ~/chump/.chump-locks/ambient.jsonl | tail -1` — all 7 samples observed in/around the window show `backend=rust`; none were `bash`/legacy.

## AC checklist

1. Start time recorded in notes — `2026-10-25T21:05Z` (also in gap notes). PASS.
2. 24 hourly probes show chumpd worker running and no legacy inline worker.sh loop — confirmed; `worker.sh` only observed as `--tick` bodies spawned by chumpd, never a standalone persistent loop. PASS.
3. `kind=worker_loop_backend backend=rust` present for the whole window — all 7 samples in-window were `backend=rust`. PASS.
4. Any gap in the window restarts it — no chumpd restart/crash events occurred in the window, so this AC is vacuously satisfied (nothing needed restarting). PASS (vacuous).

## Post-window live re-check (2026-10-28)

Re-verified on cuphead ahead of shipping this gap:

```
$ pgrep -fa 'chumpd worker'
2247236 /home/ubuntu/.cargo/bin/chumpd worker
3482578 /home/ubuntu/.cargo/bin/chumpd worker

$ pgrep -fa 'worker.sh'
<only --tick single-tick invocations, spawned by chumpd worker; no standalone inline loop>
```

Still consistent with the PASS result: chumpd owns the worker loop; `worker.sh` exists only as the short-lived `--tick` body chumpd execs, not as a competing inline loop.

## Conclusion

INFRA-8195 AC3 ("chumpd runs the worker loop end to end on cuphead for 24 hours with no worker.sh loop in the process list") is satisfied by this observation window and the post-window re-check. No further action needed; umbrella INFRA-8195 can count this AC as closed.
