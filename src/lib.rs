//! Library crate for the `chump` package (INFRA-1965 slice, INFRA-7938).
//!
//! src/main.rs is a 22k+ LOC monolith with hundreds of `mod` declarations
//! (docs/strategy/ARCHITECTURAL_CRITIQUE_2026-05-25.md C2). Prior attempts to
//! move large swaths of it in one PR (#3499) were destroyed by CI gates that
//! grep hardcoded `src/main.rs` paths (CREDIBLE-237). This crate starts the
//! decomposition with a single self-contained module and re-exports it back
//! into the binary via `pub use chump::calc_tool;` in main.rs, so
//! `crate::calc_tool` call sites elsewhere in the binary keep resolving
//! unchanged. Future slices move more modules here the same way.

pub mod calc_tool;
