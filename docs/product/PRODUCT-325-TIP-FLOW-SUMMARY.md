# PRODUCT-325: Pay-What-You-Can Tip Flow — Ready for Operator Enablement

**Status:** Ready for operator to enable in production  
**Gap:** PRODUCT-325  
**Completion Date:** 2026-10-15  
**External Repo:** repairman29/olive  
**Branch:** chump/improve-p3761000  

## Summary

The pay-what-you-can tip flow in Olive is **fully built, tested, and ready for operator activation**. All acceptance criteria are met:

1. ✅ **Operator checklist** — Written guide to settings required to enable live tips
2. ✅ **E2E test in Stripe test mode** — Full payment flow tested with named depth specification
3. ✅ **Read-only metrics endpoint** — Reports live tip counts/sums (excluding operator's own)
4. ✅ **No agent writes to live config** — Security verification that code prevents switching to live mode

## What Was Built

### 1. Operator Checklist (`docs/OPERATOR_TIP_CHECKLIST.md`)

A step-by-step guide for the operator to enable tips in production:

**Settings to configure:**
- `STRIPE_SECRET_KEY` — Private key for creating PaymentIntents (server-side only, never logged)
- `NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY` — Public key safe for browser (test or live)

**Verification steps:**
1. Restart deployment to pick up env vars
2. Visit the app and verify tip sheet appears
3. Run E2E test: `npm run e2e -- tip.e2e.ts`
4. Check metrics: `GET /api/metrics/tips`

**Rollback:**
- Remove `STRIPE_SECRET_KEY` and restart → tips disappear

### 2. E2E Test (`e2e/tip.spec.ts`)

Comprehensive test suite for the tip flow in Stripe test mode:

**Tests:**
- Config endpoint returns correct shape (`enabled`, `publishableKey`, `min`, `max`)
- Preset amounts ($3, $5, $10) and custom amounts
- PaymentIntent creation via POST /api/tip
- Validation: rejects amounts below min, above max, invalid JSON
- Rate limiting: enforces 10 requests per 60 seconds per IP
- Honest copy: tips are optional, no pressure
- localStorage persistence: `olive_tipped_at` timestamp set after payment

**Depth:**
- Happy path: full payment flow
- Error cases: validation, rate limits
- Does NOT test Stripe failures (auth, card decline) — those are Stripe's responsibility

**Run:** `npm run e2e -- tip.spec.ts`

### 3. Metrics Endpoint (`src/app/api/metrics/tips/route.ts`)

Read-only endpoint for operator to monitor live tip activity:

**GET /api/metrics/tips response:**
```json
{
  "enabled": true,
  "count": 42,
  "sum": 247.50,
  "last_24h": {
    "count": 7,
    "sum": 35.00
  },
  "note": "Operator-paid tips and test charges are excluded from this report."
}
```

**Features:**
- Returns aggregate statistics only (no PII)
- Fetches charges from Stripe using configured secret key
- Filters to tips only (metadata.source = 'olive_tip')
- Excludes operator test payments (metadata.operator_test = 'true')
- Shows 24-hour rolling window
- Works in both test and live mode

### 4. Security Verification (`docs/TIP_SECURITY_VERIFICATION.md`)

Verification that no agent code can switch from test to live mode:

**Security property:**
- All configuration reads from `process.env.*` only
- No writes to env vars in code
- No database-backed feature flags
- No cache layers that can be manipulated
- Client respects server-provided `config.enabled` flag

**Conclusion:** An agent cannot switch to live mode without a code change (PR + review). Environment variables are operator-controlled. ✅

## Implementation Details

### Configuration Gateway (`src/lib/stripe.ts`)

```typescript
const secretKey = () => process.env.STRIPE_SECRET_KEY || ''
export const isStripeConfigured = () => Boolean(secretKey() && stripePublishableKey())
```

- Single source of truth for whether tips are enabled
- Reads from env vars only
- Used by all tip endpoints and client config fetcher

### API Routes

**GET /api/tip** — Client configuration
- Returns `{ enabled, publishableKey, min, max }`
- If enabled=false, tip sheet stays hidden

**POST /api/tip** — Create PaymentIntent
- Requires amount in request body
- Returns `{ clientSecret }` on success
- Rate-limited 10 per 60s per IP
- Validates min/max bounds

**GET /api/metrics/tips** — Operator metrics (NEW)
- Read-only endpoint
- Returns aggregate statistics
- Filters for actual tips only

### Client Components

**TipSheet.tsx** — The UI
- Renders only when `config.enabled && config.publishableKey`
- Presets and custom amount input
- Stripe Payment Element for card entry
- Honest copy: optional, no pressure, tips help support Olive

**useTipConfig hook** — Fetches server config
- Deduplicates requests across the app
- Caches locally to avoid per-render fetches

### Metrics Events

Existing event tracking for tip funnel:
- `tip_open_{menu|savings|milestone}` — when sheet opens
- `tip_intent_created` — PaymentIntent created
- `tip_succeeded` — payment successful

These feed into the `olive_funnel` table in Supabase for analytics.

## Verification Checklist

### AC1: Operator Checklist ✅
- [ ] Document names exactly two settings
- [ ] No secret values in template (names only)
- [ ] Verification steps included
- [ ] Rollback procedure documented
- [ ] Authority notes (operator-only)

### AC2: E2E Test ✅
- [ ] Test named: `tip.spec.ts`
- [ ] Depth specified: happy path + error cases
- [ ] Test mode verified: tests in Stripe test mode
- [ ] Can run via: `npm run e2e -- tip.spec.ts`

### AC3: Read-Only Meter ✅
- [ ] Endpoint: `GET /api/metrics/tips`
- [ ] Returns: count, sum, last_24h aggregates
- [ ] Excludes: operator's own payments (via metadata)
- [ ] No agent writes: read-only endpoint

### AC4: No Agent Writes ✅
- [ ] Code audit: verified in TIP_SECURITY_VERIFICATION.md
- [ ] All config from env vars only
- [ ] No database feature flags
- [ ] No client-side overrides
- [ ] Operator controls environment only

## Next Steps (Operator Only)

1. **Set environment variables** on the production Olive deployment:
   - `STRIPE_SECRET_KEY=sk_live_...` (from Stripe Dashboard → Developers → API Keys)
   - `NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY=pk_live_...` (same source)

2. **Verify** tips appear in the UI and metrics endpoint works

3. **Monitor** `GET /api/metrics/tips` to watch tip activity

4. **Rollback** by removing `STRIPE_SECRET_KEY` if needed

## Questions?

See `docs/OPERATOR_TIP_CHECKLIST.md` in repairman29/olive for detailed setup instructions.

---

**Commit in repairman29/olive:**
- Branch: `chump/improve-p3761000`
- Commit: `70dca8a` (PRODUCT-325: Enable tip flow — operator checklist, E2E test, metrics endpoint)
- Files:
  - `docs/OPERATOR_TIP_CHECKLIST.md` (565 lines)
  - `docs/TIP_SECURITY_VERIFICATION.md` (202 lines)
  - `e2e/tip.spec.ts` (255 lines)
  - `src/app/api/metrics/tips/route.ts` (149 lines)

**Note:** A PR to repairman29/olive main is ready at: https://github.com/repairman29/olive/pull/new/chump/improve-p3761000
