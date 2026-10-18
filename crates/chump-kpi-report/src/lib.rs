//! chump-kpi-report — fleet KPI / impact reporting, extracted from the bin
//! crate for build speed (EFFECTIVE-418). Kept as a sibling module so
//! intra-crate `crate::` paths stay valid unchanged.
//!
//! Outbound coupling at extraction time was three edges:
//!   - `crate::gap_store::{GapStore, GapFieldUpdate}` → the existing
//!     `chump-gap-store` crate (`chump_gap_store::…`).
//!   - `crate::waste_tally::WASTE_KINDS` → the existing `chump-waste-tally`
//!     crate (`chump_waste_tally::waste_tally::…`).
//!   - `crate::session_ledger::cost_usd_from_tokens` — the per-model pricing
//!     function, still inline in the bin. Rather than promote that foundation
//!     module to a crate (out of scope, the EFFECTIVE-406 trap), the pricing
//!     function is *injected* by the bin at startup via
//!     [`kpi_report::set_cost_fn`] — the same injection contract
//!     `chump-waste-tally` uses (EFFECTIVE-411). This keeps the crate a clean
//!     leaf that depends only on the two data crates above.
pub mod admin_merges;
pub mod ci_pickup;
pub mod debt_index;
pub mod kpi_report;
pub mod live_pct;
