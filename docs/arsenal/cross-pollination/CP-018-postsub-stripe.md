# CP-018: postsub Stripe fee structure vs. Chump content-bots-suite monetization

**Source repo:** [`repairman29/postsub`](https://github.com/repairman29/postsub) — `server.js`
**Comparison repo:** [`repairman29/BEAST-MODE`](https://github.com/repairman29/BEAST-MODE) — `docs/3_YEAR_VISION_AND_ROADMAP.md`
**Parent gap:** INFRA-1850 (harvest target, parked — "defer implementation until content-bots-suite is an active workstream")
**This slice:** INFRA-5879 — document the fee structure + monetization comparison only (no vendoring, no code)

## 1. postsub `server.js` — Stripe fee structure

Fetched live via `gh api repos/repairman29/postsub/contents/server.js` (258 lines,
Express + `stripe` npm package).

```js
// Fee calculation constants
const STRIPE_FEE_PERCENTAGE = 0.029; // 2.9%
const STRIPE_FEE_FIXED = 30; // 30 cents

// Platform fee percentages by plan
const PLATFORM_FEES = {
  free: 0,
  professional: 0.05, // 5%
  enterprise: 0.03    // 3%
};
```

**Note on the gap's stated numbers:** both INFRA-1850's AC and INFRA-5879's AC
describe the tiers as "basic 5%, pro 8%, enterprise 3%". The live source does
not match that: the three `PLATFORM_FEES` keys are `free` (0%), `professional`
(5%), `enterprise` (3%) — there is no `basic` key and no `8%` value anywhere
in the file. Treat the `basic/8%` figures in both gap descriptions as a stale
or transcribed-wrong snapshot; the numbers documented above are read directly
from the current `main` branch of `repairman29/postsub`.

### Fee calculation logic (`calculateFees`)

```js
const calculateFees = (amount, planId) => {
  const stripeFee = (amount * STRIPE_FEE_PERCENTAGE) + STRIPE_FEE_FIXED;
  const platformFee = amount * (PLATFORM_FEES[planId] || 0);
  const totalFees = stripeFee + platformFee;
  const creatorRevenue = amount - totalFees;
  ...
};
```

- `amount` is in cents (Stripe convention); `stripeFee` = 2.9% + $0.30 flat,
  applied on every transaction regardless of plan.
- `platformFee` = `amount * PLATFORM_FEES[planId]` — Chump's/postsub's own
  cut, stacked on top of the Stripe processing fee.
- `creatorRevenue = amount - stripeFee - platformFee` — what the content
  creator actually receives.
- Unknown `planId` falls back to `PLATFORM_FEES[planId] || 0` → **0% platform
  fee**, i.e. the creator only pays Stripe's cut. No validation/error on an
  unrecognized plan.

### Where the fee logic is used

| Endpoint | Purpose |
|---|---|
| `POST /webhook` | Stripe webhook receiver (`checkout.session.completed`, `customer.subscription.updated/.deleted`) — logs only, no DB write shown in this file |
| `POST /api/create-checkout-session` | Stripe Checkout session, `mode: 'subscription'` |
| `POST /api/create-portal-session` | Stripe customer billing portal |
| `GET/PATCH/DELETE /api/subscriptions/:id` | Subscription CRUD via Stripe SDK directly |
| `POST /api/calculate-fees` | Exposes `calculateFees(amount, planId)` as a standalone endpoint — pure function, no side effects |
| `GET /api/revenue-analytics/:customerId` | Sums `calculateFees` over a customer's active subscriptions → `totalRevenue`, `platformFees`, `stripeFees`, `netRevenue`, `churnRate` (hardcoded mock `0.05`), `lifetimeValue` |

**Shape summary:** postsub is a **flat-percentage-per-tier** model. The
platform fee is a fixed percentage keyed off which subscription plan the
*creator* (not the buyer) is on — it does not vary per-transaction or
per-content-item. Stripe's own processing fee is always passed through
separately and stacked on top.

## 2. BEAST-MODE marketplace model — 70/30 revenue share

Fetched via `gh api repos/repairman29/BEAST-MODE/contents/docs/3_YEAR_VISION_AND_ROADMAP.md`.
The 70/30 split appears under a **Q2 2027 "AI Marketplace"** roadmap milestone
(not yet built — this is a forward-looking plan, not shipped code):

```
### Q2 2027: AI Marketplace
Priorities:
- Users can list custom models
- Revenue share model (70/30)
- Model versioning & A/B testing
- Federated learning
- $200K MRR target
```

No fee-calculation source code accompanies this — it's a roadmap bullet, not
an implementation. The shape it implies: creators who list a model/asset on
the marketplace keep **70%**, the platform takes **30%** — a single flat
split applied uniformly across all listings, independent of subscription
tier. This is the inverse structure from postsub: postsub varies the
platform's cut *by the seller's plan tier* (0/5/3%), while BEAST-MODE's
stated model is *one number for everyone* (30%), with tier differentiation
(if any) left unspecified in the roadmap doc.

## 3. Comparison

| Dimension | postsub (shipped) | BEAST-MODE (roadmap only) |
|---|---|---|
| Fee structure | Tiered by plan: 0% / 5% / 3% platform cut | Flat 30% platform cut, all sellers |
| Stripe processing fee | Passed through separately (2.9% + $0.30), stacked on top of platform fee | Not specified (no code, no doc detail) |
| Incentive shape | Rewards higher subscription tiers with a *lower* platform cut on the top tier (5% → 3%) than the mid tier — an odd inversion, possibly a bug: `professional` (5%) pays a higher rate than `enterprise` (3%), i.e. spending more to upgrade plans *reduces* the per-transaction cut | Single number, easy to communicate, but no tier-based incentive to move sellers to higher engagement |
| Maturity | Live, running code (`server.js`, `/api/calculate-fees` endpoint, revenue-analytics rollup) | Unbuilt roadmap bullet, no implementation, 2027-dated |
| Fits Chump's content-bots-suite? | Fee varies by *subscription plan*, which doesn't map cleanly onto Chump's per-gap/per-pillar output — there is no "seller subscribes to a plan" concept in the content-bots-suite design | Flat split maps more naturally onto Chump's model: each shipped content-bot artifact (PMM copy, DocuBot writeup, Evangelist post, CopyBot conversion asset) is a discrete "listing," and a flat split is simpler to reason about per-artifact than a plan-tier lookup |

## 4. Recommendation for Chump content-bots-suite (INFRA-1850, parked)

Neither model transplants directly:

- **postsub's tiered-by-plan structure doesn't fit** because content-bots-suite
  gaps are pillar/effort-tagged per-artifact (per INFRA-1850's own proposed
  design: "pillar-tag and effort-class map to fee-tier"), not per-seller-plan.
  There is no Chump equivalent of "the creator subscribes to `professional`."
- **BEAST-MODE's flat 70/30 is simpler but unproven** — it's a 2027 roadmap
  line with zero implementation to inspect, so there's no fee-calc code to
  harvest, only the ratio itself.

The best-fit shape is a **hybrid**: keep postsub's *mechanism* (a pure
`calculateFees(amount, tier)` function, Stripe fee passed through separately,
tier keyed by a Chump-native concept) but seed the *tier values* from
BEAST-MODE's flat-split intuition — e.g. map effort-class → platform-cut
percentage (`xs/s` gaps ≈ BEAST-MODE's flat 30%, `m/l` gaps discounted toward
postsub's enterprise-tier 3%) rather than importing either repo's numbers
verbatim. This confirms INFRA-1850's own AC #3 (Vendoring route, pure-function
port into `chump-billing-feecalc`) is still the right call — this brief adds
the concrete comparison data point that AC needed before implementation.

**Still parked per INFRA-1850's explicit defer clause** — content-bots-suite
(META-066/META-068) is not yet an active workstream. This brief exists so the
comparison is on record when that changes.
