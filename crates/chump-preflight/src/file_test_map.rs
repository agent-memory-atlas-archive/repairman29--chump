//! EFFECTIVE-625 (EFFECTIVE-319 slice): file-to-test mapping configuration.
//!
//! Associates file path glob patterns (e.g. `src/**/*.rs`) with one or more
//! test/gate identifiers (e.g. `unit-tests`, `clippy`). This is the small,
//! self-contained primitive that EFFECTIVE-319's future `chump impact <diff>`
//! command consumes to enumerate which gates a diff exercises — this slice
//! only defines the mapping + the matcher, no CLI.

use std::collections::BTreeSet;

/// One glob pattern -> test identifiers association.
#[derive(Debug, Clone)]
pub struct FileTestRule {
    /// Glob pattern matched against a repo-relative file path, e.g.
    /// `src/**/*.rs` or `docs/**/*.md`. Supports `*` (any run of characters
    /// within a path segment), `**` (any run of characters including `/`),
    /// and `?` (exactly one character).
    pub pattern: String,
    /// Test/gate identifiers this pattern maps to, e.g. `["unit-tests",
    /// "clippy"]`.
    pub tests: Vec<String>,
}

/// A file-to-test mapping configuration: an ordered list of rules. Order
/// does not affect matching (all matching rules contribute), but is kept
/// stable for readability/debugging.
#[derive(Debug, Clone, Default)]
pub struct FileTestMapConfig {
    pub rules: Vec<FileTestRule>,
}

impl FileTestMapConfig {
    pub fn new(rules: Vec<FileTestRule>) -> Self {
        Self { rules }
    }
}

/// Returns the union of test identifiers whose pattern matches `file_path`.
/// Empty set if no rule matches.
pub fn match_file_to_tests(file_path: &str, config: &FileTestMapConfig) -> BTreeSet<String> {
    let mut matched = BTreeSet::new();
    for rule in &config.rules {
        if glob_match(&rule.pattern, file_path) {
            matched.extend(rule.tests.iter().cloned());
        }
    }
    matched
}

/// Minimal glob matcher supporting `*`, `**`, and `?`, with `/` as the path
/// separator. `**` matches across `/`; a bare `*` does not.
fn glob_match(pattern: &str, path: &str) -> bool {
    let pat: Vec<char> = pattern.chars().collect();
    let text: Vec<char> = path.chars().collect();
    match_from(&pat, 0, &text, 0)
}

fn match_from(pat: &[char], mut pi: usize, text: &[char], mut ti: usize) -> bool {
    while pi < pat.len() {
        match pat[pi] {
            '*' => {
                // Detect `**` (matches across `/`) vs single `*` (does not).
                let is_double = pi + 1 < pat.len() && pat[pi + 1] == '*';
                let star_end = if is_double { pi + 2 } else { pi + 1 };
                // Collapse consecutive `*`/`**` runs.
                let mut next = star_end;
                while next < pat.len() && pat[next] == '*' {
                    next += 1;
                }
                if next == pat.len() {
                    // Trailing star(s) match the rest unconditionally
                    // (`**` matches everything remaining; `*` requires no
                    // more `/` in what's left).
                    if is_double {
                        return true;
                    }
                    return text[ti..].iter().all(|&c| c != '/');
                }
                if is_double {
                    // `**/` also matches zero path segments (so
                    // `src/**/*.rs` matches `src/lib.rs`, not just
                    // `src/a/lib.rs`) — try dropping the literal `/` that
                    // follows `**` together with `**` itself.
                    if pat[next] == '/' && match_from(pat, next + 1, text, ti) {
                        return true;
                    }
                    for split in ti..=text.len() {
                        if match_from(pat, next, text, split) {
                            return true;
                        }
                    }
                    return false;
                }
                for split in ti..=text.len() {
                    if text[ti..split].contains(&'/') {
                        break;
                    }
                    if match_from(pat, next, text, split) {
                        return true;
                    }
                }
                return false;
            }
            '?' => {
                if ti >= text.len() || text[ti] == '/' {
                    return false;
                }
                pi += 1;
                ti += 1;
            }
            c => {
                if ti >= text.len() || text[ti] != c {
                    return false;
                }
                pi += 1;
                ti += 1;
            }
        }
    }
    ti == text.len()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg() -> FileTestMapConfig {
        FileTestMapConfig::new(vec![
            FileTestRule {
                pattern: "src/**/*.rs".to_string(),
                tests: vec!["unit-tests".to_string(), "clippy".to_string()],
            },
            FileTestRule {
                pattern: "src/**/*.rs".to_string(),
                tests: vec!["fmt".to_string()],
            },
            FileTestRule {
                pattern: "docs/**/*.md".to_string(),
                tests: vec!["md-links".to_string()],
            },
            FileTestRule {
                pattern: "*.toml".to_string(),
                tests: vec!["cargo-check".to_string()],
            },
        ])
    }

    #[test]
    fn matches_single_pattern() {
        let got = match_file_to_tests("docs/README.md", &cfg());
        assert_eq!(got, BTreeSet::from(["md-links".to_string()]));
    }

    #[test]
    fn overlapping_patterns_union() {
        let got = match_file_to_tests("src/lib.rs", &cfg());
        assert_eq!(
            got,
            BTreeSet::from([
                "unit-tests".to_string(),
                "clippy".to_string(),
                "fmt".to_string()
            ])
        );
    }

    #[test]
    fn nested_path_matches_double_star() {
        let got = match_file_to_tests("src/coord/foo/bar.rs", &cfg());
        assert!(got.contains("unit-tests"));
        assert!(got.contains("clippy"));
        assert!(got.contains("fmt"));
    }

    #[test]
    fn no_match_returns_empty_set() {
        let got = match_file_to_tests("README.txt", &cfg());
        assert!(got.is_empty());
    }

    #[test]
    fn single_star_does_not_cross_slash() {
        let got = match_file_to_tests("Cargo.toml", &cfg());
        assert_eq!(got, BTreeSet::from(["cargo-check".to_string()]));

        let got_nested = match_file_to_tests("crates/foo/Cargo.toml", &cfg());
        assert!(got_nested.is_empty());
    }

    #[test]
    fn empty_config_returns_empty_set() {
        let got = match_file_to_tests("anything.rs", &FileTestMapConfig::default());
        assert!(got.is_empty());
    }
}
