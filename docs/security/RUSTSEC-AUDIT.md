# RustSec Advisory Audit — chump

_Last updated: 2026-05-08 (INFRA-696)_

## Summary

| Advisory | Crate | Severity | Status | Blocked by |
|---|---|---|---|---|
| RUSTSEC-2023-0071 | rsa 0.9.10 | Medium (5.9) | Not reachable — see below | No fix available upstream |
| RUSTSEC-2026-0049 | rustls-webpki 0.102.8 | Medium | Ignored in CI | serenity 0.12 → rustls 0.22 |
| RUSTSEC-2026-0098 | rustls-webpki 0.102.8 | Medium | Ignored in CI | serenity 0.12 → rustls 0.22 |
| RUSTSEC-2026-0099 | rustls-webpki 0.102.8 | Medium | Ignored in CI | serenity 0.12 → rustls 0.22 |
| RUSTSEC-2026-0104 | rustls-webpki 0.102.8 | High | Ignored in CI | serenity 0.12 → rustls 0.22 |

---

## RUSTSEC-2023-0071 — rsa Marvin Attack (web-push chain)

**Advisory:** https://rustsec.org/advisories/RUSTSEC-2023-0071  
**Affected operation:** RSA PKCS#1 v1.5 *decryption* via timing side-channel.

### Dependency path

```
chump → web-push 0.11.0 → jwt-simple 0.12.15 → superboring 0.1.10 → rsa 0.9.10
```

### Reachability verdict: NOT REACHABLE

The `rsa` crate enters the build only as a transitive dependency of `jwt-simple`, which
supports multiple signing algorithms (ES256, RS256, etc.). Chump exclusively uses VAPID for
web-push authentication, which is specified by the W3C Push API to use **ECDH/ECDSA with
P-256**. Chump's `web_push_send.rs` calls `VapidSignatureBuilder` with a PEM-encoded EC
private key — no RSA key, no RSA operation.

The Marvin Attack requires an attacker to interact with an RSA PKCS#1 *decryption* oracle
(i.e., the server must decrypt attacker-supplied ciphertext and leak timing). Chump is the
push *sender*, not a decryption oracle. The `rsa::decrypt` code path is never invoked.

**Evidence:**
- `src/web_push_send.rs` uses `VapidSignatureBuilder` from the `web-push` crate — EC only.
- No `rsa` or `jwt_simple` imports appear anywhere in `src/`.
- No RSA private key is configured or used at runtime.

### Remediation path

There is no fixed version of `rsa` available as of 2026-05-08 (RUSTSEC advisory notes "no
fixed upgrade available"). Monitor https://rustsec.org/advisories/RUSTSEC-2023-0071 for
upstream resolution. The risk remains acceptable given non-reachability; re-assess if
chump ever adds an RSA-signing JWT flow.

---

## RUSTSEC-2026-0104 / 0098 / 0099 / 0049 — rustls-webpki advisories

**Advisories:** RUSTSEC-2026-0104 (HIGH — panic in CRL parsing), RUSTSEC-2026-0098 (URI
name constraints), RUSTSEC-2026-0099 (wildcard name constraints), RUSTSEC-2026-0049 (CRL
distribution point matching).

**Fix:** Upgrade `rustls-webpki` to ≥ 0.103.12 (for -0098/-0099/-0049) or ≥ 0.103.13
(for -0104). This requires `rustls` ≥ 0.23, which is a semver-breaking upgrade.

### Dependency path

```
chump --feature discord → serenity 0.12.5 → tokio-tungstenite 0.21 → tungstenite 0.21
  → tokio-rustls 0.25 → rustls 0.22.4 → rustls-webpki 0.102.8
```

### Reachability

- The `discord` feature is **off by default** (`Cargo.toml` line 74). Default builds do
  not compile this chain.
- When `discord` is enabled: chump connects to the Discord WebSocket gateway only. Discord's
  gateway does not send Certificate Revocation Lists (CRLs) over the WebSocket connection.
  The rustls-webpki panic path (RUSTSEC-2026-0104) requires parsing a malformed CRL
  BIT STRING — this cannot be triggered via Discord's WS-only protocol.

### Upgrade block

`serenity 0.12.5` is the latest release on crates.io as of 2026-05-08 and pins
`tokio-tungstenite 0.21` which transitively requires `rustls 0.22`. There is no supported
upgrade path without breaking serenity's dependency contract.

`cargo update -p "rustls-webpki@0.102.8"` finds no compatible upgrade within the 0.102.x
series (no fix exists for 0.102.x; the fix branch is 0.103.x).

### Remediation path

Re-audit when `serenity` releases a version using `tokio-tungstenite ≥ 0.22` (which
requires `rustls ≥ 0.23`). Track via gap RELIABILITY-001 / SECURITY-005. Until then, all
four advisories are explicitly ignored in `.github/workflows/cargo-audit-nightly.yml` with
this documentation as the justification record.

### CI status

The blocking `cargo audit` step in `cargo-audit-nightly.yml` passes with `--ignore` flags
for all four advisories. No new HIGH/CRITICAL advisories on the `rustls*` tree are
unaccounted for as of the date above.

---

## 2026-10-24 Triage Update (CREDIBLE-1536 / CREDIBLE-1540)

Canonical ignore lists are now synchronized across `.cargo/audit.toml`, `deny.toml`, and
`.github/workflows/cargo-audit-nightly.yml` so both `cargo audit` (nightly + weekly) and
`cargo deny --format human check advisories bans` evaluate the same triaged baseline:

- **`crypto-bigint` (`RUSTSEC-2026-0387`) & `ctutils` (`RUSTSEC-2026-0385`):** pulled in
  transitively through `web-push -> jwt-simple -> superboring -> rsa`. Not reachable because
  Chump uses EC/P-256 VAPID keys exclusively.
- **`rustls 0.21` (`RUSTSEC-2026-0346`, `RUSTSEC-2026-0349`), `rustls-webpki`
  (`RUSTSEC-2026-0382`), `webpki-roots` (`RUSTSEC-2026-0381`), `webpki-root-certs`
  (`RUSTSEC-2026-0383`):** transitive TLS dependencies blocked on upstream `serenity` /
  `tokio-rustls` semver boundaries.
- **`h2` (`RUSTSEC-2026-0258`) & `quinn-proto` (`RUSTSEC-2026-0338`..`0342`):** client-only
  HTTP/2 and optional QUIC transport dependencies; Chump does not expose a public-facing H2
  or QUIC server to untrusted internet peers.
- **`wasmtime` / `wasmtime-wasi` (`RUSTSEC-2026-0316`, `0321`..`0327`, `0352`..`0364`,
  `0378`, `0379`):** Component Model, Wasm GC, Wasm exceptions, and WASI preview0/preview3
  guest-escape advisories; Chump only executes operator-built tool modules and does not
  enable untrusted multi-tenant Component Model async lifting, Wasm GC, or host-dir mounts.
- **`zip 7.2.0` (`RUSTSEC-2026-0367`..`0369`):** transitive archive dependency blocked on
  upstream migration to `zip >= 9.0.0`.
