---
doc_tag: audit
owner_gap: PRODUCT-314
status: fix-shipped-pending-ci
---

# PRODUCT-314 — beast-mode.dev sign-in CTA 307s to a dead Supabase host

## 1. Reproduction (confirmed live, 2026-10-01)

```
$ curl -sI https://beast-mode.dev/api/auth/github
HTTP/2 307
location: https://fsmibduqvwnfyvypuaie.supabase.co/auth/v1/authorize?provider=github&...

$ getent hosts fsmibduqvwnfyvypuaie.supabase.co
(exit 2 — NXDOMAIN)
```

Both primary sign-in CTAs on the homepage ("Initialize Beast Mode" hero
button and the "Execute" terminal-footer button in
`website/app/page.tsx`) are plain `<a href="/api/auth/github">` links —
every anonymous visitor who clicks either one is 307-redirected straight
into a host that doesn't resolve. Dead funnel, confirmed reproducible.

## 2. Root cause

`repairman29/BEAST-MODE` (website deployed to beast-mode.dev via Vercel).
`website/app/api/auth/github/route.ts` builds the OAuth redirect from
`process.env.NEXT_PUBLIC_SUPABASE_URL`, which is set in Vercel to
`https://fsmibduqvwnfyvypuaie.supabase.co`. The repo's own
`website/app/api/debug/auth-config/route.ts` diagnostic documents this as
the *correct* project ref (as opposed to an old Echeo project the app once
used) — so this isn't a stale/wrong-env-var misconfiguration. The Supabase
project itself (`fsmibduqvwnfyvypuaie`) no longer resolves — deleted or
paused (Supabase free-tier projects pause after a period of inactivity).
Resurrecting it requires Supabase Dashboard access, which is outside the
scope of a code fix and outside this chump checkout.

The password sign-in path (`/api/auth/signin`) hits the same dead project
via the Supabase JS client and fails with `fetch failed` — consistent with
the same root cause, not a separate bug.

## 3. Fix (AC #1 / #2)

Since there's no live Supabase project to redirect to, the CTA is made
defensive rather than disabled outright: `website/app/api/auth/github/route.ts`
now probes the Supabase auth endpoint (`AbortSignal.timeout(3000)`, same
pattern already used elsewhere in this codebase, e.g.
`app/api/beast-mode/quality/quick/route.ts`) before issuing the OAuth
redirect. If the host doesn't respond, the visitor is sent back to `/`
with `?error=auth_unavailable` instead of into a non-resolving host. Once
a live Supabase project is wired up (`NEXT_PUBLIC_SUPABASE_URL` updated in
Vercel), the probe passes through and the real OAuth flow is unchanged.

Shipped as `repairman29/BEAST-MODE#45`
(branch `fix/product-314-dead-supabase-auth-funnel`), auto-merge armed —
repo is active (not archived) and this session has admin push access, so
unlike PRODUCT-312's `repairman29/dice` this didn't need to stop at a
prepared-but-unpushed patch.

## 4. Next steps (operator decision)

1. Provision/restore a live Supabase project and point
   `NEXT_PUBLIC_SUPABASE_URL` + `NEXT_PUBLIC_SUPABASE_ANON_KEY` at it in
   Vercel, so sign-in actually works again instead of just failing safely.
2. Until then, the CTA degrades to "bounce home with an error flag" rather
   than a dead-end redirect — closes the AC, but sign-up/sign-in is still
   non-functional end-to-end pending step 1.
