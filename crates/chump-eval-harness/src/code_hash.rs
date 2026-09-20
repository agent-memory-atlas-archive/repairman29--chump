//! Deterministic code hash for test inputs (META-203 slice: test-result
//! cache layer). Given a test's source files and dependency files, produce a
//! stable SHA-256 digest so a test runner can skip re-execution when none of
//! the inputs changed since the last recorded run.

use anyhow::{Context, Result};
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};

/// Computes a deterministic SHA-256 hash over the contents of `paths`.
///
/// Paths are sorted before hashing (independent of caller-supplied order),
/// and each entry's hash contribution is `path\0<len-prefixed content>` so
/// the digest changes if either the file's content or its path changes.
/// Missing files are treated as empty content rather than erroring, so a
/// dependency that hasn't been created yet still contributes a stable value.
pub fn compute_code_hash<P: AsRef<Path>>(paths: &[P]) -> Result<String> {
    let mut sorted: Vec<PathBuf> = paths.iter().map(|p| p.as_ref().to_path_buf()).collect();
    sorted.sort();

    let mut hasher = Sha256::new();
    for path in &sorted {
        let contents = match std::fs::read(path) {
            Ok(bytes) => bytes,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Vec::new(),
            Err(e) => return Err(e).context(format!("reading {} for code hash", path.display())),
        };
        hasher.update(path.to_string_lossy().as_bytes());
        hasher.update(b"\0");
        hasher.update(contents.len().to_le_bytes());
        hasher.update(&contents);
    }

    Ok(hex::encode(hasher.finalize()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn identical_code_produces_same_hash() {
        let dir = tempdir();
        let file_a = dir.join("a.rs");
        let file_b = dir.join("b.rs");
        fs::write(&file_a, b"fn a() {}").unwrap();
        fs::write(&file_b, b"fn b() {}").unwrap();

        let hash1 = compute_code_hash(&[&file_a, &file_b]).unwrap();
        // Reversed input order must still be deterministic (sorted internally).
        let hash2 = compute_code_hash(&[&file_b, &file_a]).unwrap();

        assert_eq!(hash1, hash2);

        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn changed_code_produces_different_hash() {
        let dir = tempdir();
        let file_a = dir.join("a.rs");
        fs::write(&file_a, b"fn a() {}").unwrap();
        let before = compute_code_hash(&[&file_a]).unwrap();

        fs::write(&file_a, b"fn a() { println!(\"changed\"); }").unwrap();
        let after = compute_code_hash(&[&file_a]).unwrap();

        assert_ne!(before, after);

        fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn missing_file_does_not_error() {
        let dir = tempdir();
        let missing = dir.join("does-not-exist.rs");

        let result = compute_code_hash(&[&missing]);
        assert!(result.is_ok());

        fs::remove_dir_all(&dir).unwrap();
    }

    fn tempdir() -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "chump-code-hash-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::create_dir_all(&dir).unwrap();
        dir
    }
}
