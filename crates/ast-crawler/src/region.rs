//! Region resolution — INFRA-5759 (INFRA-1689 slice).
//!
//! `chump claim --region <file>::<symbol>` (INFRA-5758) stores the region as
//! an opaque `file::symbol` string; nothing yet validates that the symbol
//! actually maps to a real AST node, or knows where that node starts/ends.
//! This module closes that gap: given a file and a `symbol` path (a plain
//! name like `dispatch_fanout`, or a `Container::member` pair for a method
//! inside an `impl`/`class` block), it parses the file with tree-sitter and
//! returns the line range the symbol covers.
//!
//! v1 languages (INFRA-1689 AC): Rust, TypeScript, Python. Any other
//! language — including the v1-crawler's own bash/go/yaml support — falls
//! through cleanly: a one-line stderr note is printed and the caller gets
//! [`RegionResolution::UnsupportedLanguage`], meaning "treat this as a
//! file-level claim."

use anyhow::{Context, Result};
use std::path::Path;
use tree_sitter::{Node, Parser};

/// The AST range a resolved symbol covers, 1-based inclusive line numbers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SymbolRange {
    /// Coarse kind: `fn`, `struct`, `impl`, `class`, `interface`, `method`.
    pub kind: String,
    pub start_line: usize,
    pub end_line: usize,
}

/// Outcome of attempting to resolve a `file::symbol` region.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RegionResolution {
    /// Symbol found; here is its AST range.
    Resolved(SymbolRange),
    /// The file's language parsed fine, but no node matched `symbol`.
    NotFound,
    /// The file's language is not one of the v1 region languages
    /// (Rust/TypeScript/Python). A stderr note was already printed.
    UnsupportedLanguage,
}

/// Resolve `symbol` (e.g. `dispatch_fanout` or `Widget::make`) against the
/// AST of `path`. `symbol` may name a top-level `fn`/`struct`/`impl`/`class`/
/// `interface` directly, or `Container::member` to reach a method inside an
/// `impl`/`class` body.
pub fn resolve_region(path: &Path, symbol: &str) -> Result<RegionResolution> {
    let lang = detect_region_language(path);
    let Some(lang) = lang else {
        eprintln!(
            "ast-crawler: {} is not a v1 region language (Rust/TypeScript/Python) — \
             falling back to file-level claim",
            path.display()
        );
        return Ok(RegionResolution::UnsupportedLanguage);
    };

    let src = std::fs::read_to_string(path).with_context(|| format!("read {}", path.display()))?;
    let mut parts = symbol.splitn(2, "::");
    let head = parts.next().unwrap_or(symbol);
    let member = parts.next();

    match lang {
        RegionLanguage::Rust => Ok(resolve_rust(&src, head, member)),
        RegionLanguage::TypeScript { tsx } => Ok(resolve_typescript(&src, head, member, tsx)),
        RegionLanguage::Python => Ok(resolve_python(&src, head, member)),
    }
}

enum RegionLanguage {
    Rust,
    TypeScript { tsx: bool },
    Python,
}

fn detect_region_language(path: &Path) -> Option<RegionLanguage> {
    if let Some(name) = path.file_name().and_then(|s| s.to_str()) {
        if name.ends_with(".d.ts") {
            return Some(RegionLanguage::TypeScript { tsx: false });
        }
    }
    let ext = path
        .extension()
        .and_then(|s| s.to_str())
        .map(|s| s.to_ascii_lowercase())
        .unwrap_or_default();
    match ext.as_str() {
        "rs" => Some(RegionLanguage::Rust),
        "ts" => Some(RegionLanguage::TypeScript { tsx: false }),
        "tsx" => Some(RegionLanguage::TypeScript { tsx: true }),
        "py" => Some(RegionLanguage::Python),
        _ => None,
    }
}

fn node_range(node: Node, kind: &str) -> SymbolRange {
    SymbolRange {
        kind: kind.to_string(),
        start_line: node.start_position().row + 1,
        end_line: node.end_position().row + 1,
    }
}

fn node_name<'a>(node: Node<'a>, src: &'a str) -> Option<&'a str> {
    let n = node.child_by_field_name("name")?;
    n.utf8_text(src.as_bytes()).ok().map(|s| s.trim())
}

// ── Rust ─────────────────────────────────────────────────────────────────

fn resolve_rust(src: &str, head: &str, member: Option<&str>) -> RegionResolution {
    let mut parser = Parser::new();
    if parser
        .set_language(&tree_sitter_rust::LANGUAGE.into())
        .is_err()
    {
        return RegionResolution::NotFound;
    }
    let Some(tree) = parser.parse(src, None) else {
        return RegionResolution::NotFound;
    };
    let root = tree.root_node();
    let mut cursor = root.walk();

    for child in root.named_children(&mut cursor) {
        match child.kind() {
            "function_item" | "struct_item" | "enum_item" | "trait_item" | "mod_item" => {
                if node_name(child, src) == Some(head) && member.is_none() {
                    let kind = match child.kind() {
                        "function_item" => "fn",
                        "struct_item" => "struct",
                        "enum_item" => "enum",
                        "trait_item" => "trait",
                        _ => "mod",
                    };
                    return RegionResolution::Resolved(node_range(child, kind));
                }
            }
            "impl_item" => {
                let type_name = child
                    .child_by_field_name("type")
                    .and_then(|n| n.utf8_text(src.as_bytes()).ok())
                    .map(|s| s.trim());
                if type_name == Some(head) {
                    match member {
                        None => return RegionResolution::Resolved(node_range(child, "impl")),
                        Some(m) => {
                            if let Some(body) = child.child_by_field_name("body") {
                                let mut bc = body.walk();
                                for item in body.named_children(&mut bc) {
                                    if item.kind() == "function_item"
                                        && node_name(item, src) == Some(m)
                                    {
                                        return RegionResolution::Resolved(node_range(item, "fn"));
                                    }
                                }
                            }
                        }
                    }
                }
            }
            _ => {}
        }
    }
    RegionResolution::NotFound
}

// ── TypeScript ───────────────────────────────────────────────────────────

fn resolve_typescript(src: &str, head: &str, member: Option<&str>, tsx: bool) -> RegionResolution {
    let mut parser = Parser::new();
    let lang: tree_sitter::Language = if tsx {
        tree_sitter_typescript::LANGUAGE_TSX.into()
    } else {
        tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into()
    };
    if parser.set_language(&lang).is_err() {
        return RegionResolution::NotFound;
    }
    let Some(tree) = parser.parse(src, None) else {
        return RegionResolution::NotFound;
    };
    let root = tree.root_node();
    let mut cursor = root.walk();

    for child in root.named_children(&mut cursor) {
        let mut item = child;
        if item.kind() == "export_statement" {
            if let Some(decl) = item.child_by_field_name("declaration") {
                item = decl;
            } else {
                continue;
            }
        }
        match item.kind() {
            "function_declaration" if member.is_none() => {
                if node_name(item, src) == Some(head) {
                    return RegionResolution::Resolved(node_range(item, "fn"));
                }
            }
            "interface_declaration" if member.is_none() => {
                if node_name(item, src) == Some(head) {
                    return RegionResolution::Resolved(node_range(item, "interface"));
                }
            }
            "class_declaration" => {
                if node_name(item, src) == Some(head) {
                    match member {
                        None => return RegionResolution::Resolved(node_range(item, "class")),
                        Some(m) => {
                            if let Some(body) = item.child_by_field_name("body") {
                                let mut bc = body.walk();
                                for method in body.named_children(&mut bc) {
                                    if method.kind() == "method_definition"
                                        && node_name(method, src) == Some(m)
                                    {
                                        return RegionResolution::Resolved(node_range(
                                            method, "method",
                                        ));
                                    }
                                }
                            }
                        }
                    }
                }
            }
            _ => {}
        }
    }
    RegionResolution::NotFound
}

// ── Python ───────────────────────────────────────────────────────────────

fn resolve_python(src: &str, head: &str, member: Option<&str>) -> RegionResolution {
    let mut parser = Parser::new();
    if parser
        .set_language(&tree_sitter_python::LANGUAGE.into())
        .is_err()
    {
        return RegionResolution::NotFound;
    }
    let Some(tree) = parser.parse(src, None) else {
        return RegionResolution::NotFound;
    };
    let root = tree.root_node();
    let mut cursor = root.walk();

    for child in root.named_children(&mut cursor) {
        match child.kind() {
            "function_definition" if member.is_none() => {
                if node_name(child, src) == Some(head) {
                    return RegionResolution::Resolved(node_range(child, "fn"));
                }
            }
            "class_definition" => {
                if node_name(child, src) == Some(head) {
                    match member {
                        None => return RegionResolution::Resolved(node_range(child, "class")),
                        Some(m) => {
                            if let Some(body) = child.child_by_field_name("body") {
                                let mut bc = body.walk();
                                for item in body.named_children(&mut bc) {
                                    if item.kind() == "function_definition"
                                        && node_name(item, src) == Some(m)
                                    {
                                        return RegionResolution::Resolved(node_range(item, "fn"));
                                    }
                                }
                            }
                        }
                    }
                }
            }
            _ => {}
        }
    }
    RegionResolution::NotFound
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn write_tmp(dir: &Path, name: &str, body: &str) -> std::path::PathBuf {
        let p = dir.join(name);
        let mut f = std::fs::File::create(&p).unwrap();
        f.write_all(body.as_bytes()).unwrap();
        p
    }

    #[test]
    fn rust_resolves_fn_struct_and_impl_method_ranges() {
        let td = tempfile::tempdir().unwrap();
        let body = r#"
struct Widget {
    size: u32,
}

impl Widget {
    fn make(size: u32) -> Self {
        Widget { size }
    }
}

fn dispatch_fanout() {
    println!("go");
}
"#;
        let p = write_tmp(td.path(), "lib.rs", body);

        let r = resolve_region(&p, "dispatch_fanout").unwrap();
        match r {
            RegionResolution::Resolved(range) => {
                assert_eq!(range.kind, "fn");
                assert!(range.start_line < range.end_line);
            }
            other => panic!("expected Resolved, got {other:?}"),
        }

        let r = resolve_region(&p, "Widget").unwrap();
        assert!(matches!(
            r,
            RegionResolution::Resolved(SymbolRange { ref kind, .. }) if kind == "struct"
        ));

        let r = resolve_region(&p, "Widget::make").unwrap();
        match r {
            RegionResolution::Resolved(range) => assert_eq!(range.kind, "fn"),
            other => panic!("expected Resolved method, got {other:?}"),
        }

        let r = resolve_region(&p, "does_not_exist").unwrap();
        assert_eq!(r, RegionResolution::NotFound);
    }

    #[test]
    fn typescript_resolves_class_and_method_ranges() {
        let td = tempfile::tempdir().unwrap();
        let body = r#"
export interface Widget { size: number; }

export class Greeter {
    greet(): string {
        return "hi";
    }
}

export function dispatchFanout(): void {}
"#;
        let p = write_tmp(td.path(), "thing.ts", body);

        let r = resolve_region(&p, "dispatchFanout").unwrap();
        assert!(matches!(
            r,
            RegionResolution::Resolved(SymbolRange { ref kind, .. }) if kind == "fn"
        ));

        let r = resolve_region(&p, "Widget").unwrap();
        assert!(matches!(
            r,
            RegionResolution::Resolved(SymbolRange { ref kind, .. }) if kind == "interface"
        ));

        let r = resolve_region(&p, "Greeter::greet").unwrap();
        match r {
            RegionResolution::Resolved(range) => assert_eq!(range.kind, "method"),
            other => panic!("expected Resolved method, got {other:?}"),
        }
    }

    #[test]
    fn python_resolves_class_and_method_ranges() {
        let td = tempfile::tempdir().unwrap();
        let body = r#"
class Widget:
    def make(self):
        return 1

def dispatch_fanout():
    return None
"#;
        let p = write_tmp(td.path(), "thing.py", body);

        let r = resolve_region(&p, "dispatch_fanout").unwrap();
        assert!(matches!(
            r,
            RegionResolution::Resolved(SymbolRange { ref kind, .. }) if kind == "fn"
        ));

        let r = resolve_region(&p, "Widget").unwrap();
        assert!(matches!(
            r,
            RegionResolution::Resolved(SymbolRange { ref kind, .. }) if kind == "class"
        ));

        let r = resolve_region(&p, "Widget::make").unwrap();
        match r {
            RegionResolution::Resolved(range) => assert_eq!(range.kind, "fn"),
            other => panic!("expected Resolved method, got {other:?}"),
        }
    }

    #[test]
    fn unsupported_language_falls_back_with_stderr_note() {
        let td = tempfile::tempdir().unwrap();
        let p = write_tmp(td.path(), "tool.sh", "hello() { echo hi; }\n");
        let r = resolve_region(&p, "hello").unwrap();
        assert_eq!(r, RegionResolution::UnsupportedLanguage);
    }
}
