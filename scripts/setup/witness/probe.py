#!/usr/bin/env python3
"""Pixel witness — the fleet's black box (RESILIENT-335, Stage 1).

Probes the patient (helsinki) over the tailnet + checks trunk liveness via
GitHub's public API (independent truth path, no token). Alerts the CTO by
Discord DM — a path that touches neither helsinki nor the Mac — after 3
consecutive dark probes (~15 min), and again on recovery. Trunk-silent
(>6h without a commit) alerts at most once per 12h.

State: ~/witness/state.json · Log: ~/witness/witness.jsonl
Creds: ~/.witness-env (DISCORD_TOKEN, CHUMP_READY_DM_USER_ID) — 600, never logged.
"""
import calendar, json, os, pathlib, socket, subprocess, time, urllib.request

HOME = pathlib.Path.home()
W = HOME / "witness"
W.mkdir(exist_ok=True)
STATE = W / "state.json"
HELSINKI = "100.101.188.30"

def load_env():
    env = {}
    try:
        for line in (HOME / ".witness-env").read_text().splitlines():
            if "=" in line and not line.startswith("#"):
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip()
    except Exception:
        pass
    return env

def tcp(host, port, timeout=6):
    try:
        with socket.create_connection((host, port), timeout=timeout):
            return True
    except Exception:
        return False

def trunk_age_hours():
    try:
        req = urllib.request.Request(
            "https://api.github.com/repos/repairman29/chump/commits?per_page=1",
            headers={"User-Agent": "pixel-witness/1.0"})
        with urllib.request.urlopen(req, timeout=15) as r:
            ts = json.loads(r.read())[0]["commit"]["committer"]["date"]
        t = calendar.timegm(time.strptime(ts, "%Y-%m-%dT%H:%M:%SZ"))
        return round((time.time() - t) / 3600, 1)
    except Exception:
        return None  # network problem on OUR side — never alert on this alone

def dm(env, text):
    tok, uid = env.get("DISCORD_TOKEN"), env.get("CHUMP_READY_DM_USER_ID")
    if not (tok and uid):
        return "no-creds"
    # Operator kill-switch (Jeff, 2026-09-13): the witness probe is an automated
    # dead-man's-switch page, not a reply to a message Jeff sent — suppressed
    # unless CHUMP_OPERATOR_AUTOPOST_DM re-enables automated operator DMs.
    if os.environ.get("CHUMP_OPERATOR_AUTOPOST_DM", "").strip().lower() not in (
        "1", "true", "on", "yes",
    ):
        return "suppressed-autoposts-off"
    try:
        def req(path, body):
            r = urllib.request.Request(
                "https://discord.com/api/v10" + path, method="POST",
                headers={"Authorization": f"Bot {tok}",
                         "Content-Type": "application/json",
                         "User-Agent": "pixel-witness/1.0"},
                data=json.dumps(body).encode())
            with urllib.request.urlopen(r, timeout=15) as resp:
                return json.loads(resp.read())
        cid = (W / "dm-channel").read_text().strip() if (W / "dm-channel").exists() else None
        if not cid:
            cid = str(req("/users/@me/channels", {"recipient_id": uid})["id"])
            (W / "dm-channel").write_text(cid)
        req(f"/channels/{cid}/messages", {"content": text[:1900]})
        return "sent"
    except Exception as e:
        return f"failed:{type(e).__name__}"

def battery():
    try:
        out = subprocess.run(["termux-battery-status"], capture_output=True,
                             text=True, timeout=10).stdout
        b = json.loads(out)
        return {"plugged": b.get("plugged"), "pct": b.get("percentage")}
    except Exception:
        return None


def main():
    st = json.loads(STATE.read_text()) if STATE.exists() else {}
    env = load_env()
    ssh_ok = tcp(HELSINKI, 22)
    nats_ok = tcp(HELSINKI, 4222)
    age = trunk_age_hours()
    now = time.time()

    dark = not (ssh_ok or nats_ok)
    st["dark_count"] = st.get("dark_count", 0) + 1 if dark else 0
    alert = None
    if dark and st["dark_count"] == 3:
        alert = (f"🚨 WITNESS (pixel): helsinki unreachable from the cabinet-independent "
                 f"path for ~{st['dark_count']*5} min (ssh+nats both dark). "
                 f"Last trunk commit: {age if age is not None else '?'}h ago.")
        st["was_dark"] = True
    elif not dark and st.get("was_dark"):
        alert = "✅ WITNESS (pixel): helsinki reachable again."
        st["was_dark"] = False
    bat = battery()
    if bat:
        on_ac = bat["plugged"] != "UNPLUGGED"
        was_ac = st.get("on_ac", True)
        if was_ac and not on_ac:
            alert = (alert + "\n" if alert else "") + \
                (f"🔌 WITNESS (pixel): lost AC power — running on battery ({bat['pct']}%). "
                 f"House power event, or someone unplugged me.")
        elif not was_ac and on_ac:
            alert = (alert + "\n" if alert else "") + "🔌 WITNESS (pixel): AC power restored."
        elif not on_ac and bat["pct"] is not None and bat["pct"] < 20 and not st.get("low_batt_alerted"):
            alert = (alert + "\n" if alert else "") + \
                f"🪫 WITNESS (pixel): battery {bat['pct']}% and falling — I go dark soon."
            st["low_batt_alerted"] = True
        if on_ac:
            st["low_batt_alerted"] = False
        st["on_ac"] = on_ac
    if age is not None and age > 6 and now - st.get("last_trunk_alert", 0) > 43200:
        alert = (alert + "\n" if alert else "") + \
            f"⚠️ WITNESS (pixel): trunk silent — last chump commit {age}h ago."
        st["last_trunk_alert"] = now

    rec = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
           "ssh": ssh_ok, "nats": nats_ok, "trunk_age_h": age,
           "dark_count": st["dark_count"],
           "battery": bat}
    if alert:
        rec["alert"] = dm(env, alert)
    with open(W / "witness.jsonl", "a") as f:
        f.write(json.dumps(rec) + "\n")
    STATE.write_text(json.dumps(st))
    print(json.dumps(rec))

if __name__ == "__main__":
    main()
