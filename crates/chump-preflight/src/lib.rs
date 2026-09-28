//! chump-preflight — the `chump preflight` local CI mirror, extracted from the
//! chump bin (EFFECTIVE-400) so it compiles and caches as its own crate.
//!
//! The bin re-exports this module (`pub use chump_preflight::preflight;`) so
//! existing `preflight::run(..)` callers stay unchanged.

pub mod artifact_gates;
pub mod file_test_map;
pub mod preflight;
