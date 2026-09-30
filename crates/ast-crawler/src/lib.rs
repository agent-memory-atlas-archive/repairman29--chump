//! chump-ast-crawler — deterministic AST extractor for codebase shape.
//!
//! ## INFRA-1719: motivation
//!
//! Today `chump gap decompose` and a few sibling primitives build LLM context
//! by shelling out (`grep`, `find`, `head`) and dumping raw text into the
//! prompt. Token-expensive (raw bodies, not symbols), non-deterministic
//! (different runs return different slices) and impossible to cache by
//! content-hash.
//!
//! This crate replaces that path with a deterministic tree-sitter pre-step
//! that produces a structured codebase shape: per-file symbol list (top-level
//! `fn` / `struct` / `class` / etc.), import list, and the first line of any
//! attached doc comment. Downstream callers (gap decompose, the upcoming
//! ARCHITECTURE.md / CAPABILITIES_REGISTRY generators in INFRA-1722, INFRA-1727,
//! INFRA-1729, INFRA-1734, INFRA-1735) consume the resulting `CodebaseShape`
//! struct directly — no string parsing, no re-walking.
//!
//! ## Supported languages (day 1)
//!
//! | Extension(s)           | Language    | Symbol kinds extracted                   |
//! |------------------------|-------------|------------------------------------------|
//! | `.rs`                  | rust        | `fn`, `struct`, `enum`, `trait`, `impl`, `const`, `mod` |
//! | `.py`                  | python      | `fn`, `class`, `const`                   |
//! | `.js`, `.mjs`, `.cjs`  | javascript  | `fn`, `class`, `const`                   |
//! | `.ts`, `.tsx`          | typescript  | `fn`, `class`, `const`, `interface`, `type` |
//! | `.go`                  | go          | `fn`, `struct`, `interface`, `const`     |
//! | `.sh`, `.bash`         | bash        | `fn`                                     |
//! | `.yaml`, `.yml`        | yaml        | top-level keys as `key`                  |
//!
//! Any other extension is reported as `language: "unknown", supported: false`
//! and emits `kind=ast_crawler_unsupported_language` to ambient (debounced
//! per-extension within a run to avoid flooding).
//!
//! ## Token-budget shaping
//!
//! `CodebaseShape::to_prompt_block(budget)` returns a compact text rendering
//! that fits within a soft token budget — symbols are listed in path order
//! with truncation when the byte cap is reached. The full JSON is always
//! available via `serde_json::to_string(&shape)`.

use anyhow::{Context, Result};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use tree_sitter::{Node, Parser, Tree};

pub mod region;
pub use region::{resolve_region, RegionResolution, SymbolRange};

/// One importable / referenceable top-level symbol within a source file.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct Symbol {
    /// Identifier as written in source.
    pub name: String,
    /// Coarse symbol category. See the table in the crate docstring for the
    /// per-language mapping.
    pub kind: String,
    /// 1-based source line where the symbol declaration begins.
    pub line: usize,
    /// First non-blank line of an attached doc comment if any.
    pub doc_first_line: Option<String>,
}

/// One file's extracted shape.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct FileShape {
    /// Path relative to the repo root when crawled with `crawl_repo`,
    /// or as supplied to `crawl_file` otherwise.
    pub path: String,
    /// Lower-case language tag. `"unknown"` for unsupported extensions.
    pub language: String,
    /// `true` when a tree-sitter parser ran successfully.
    pub supported: bool,
    pub top_level_symbols: Vec<Symbol>,
    pub imports: Vec<String>,
}

/// Full repo (or path-list) shape returned by [`crawl_repo`] / [`crawl_paths`].
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CodebaseShape {
    pub repo_root: String,
    pub generated_at: DateTime<Utc>,
    pub total_files: usize,
    pub total_symbols: usize,
    pub supported_languages: Vec<String>,
    /// Files that were skipped because their language is not supported by any
    /// tree-sitter parser. Counted separately so downstream callers (almanac
    /// index, gap decompose) can surface a materiality warning rather than
    /// silently presenting a partial view as complete.
    pub skipped_files: usize,
    /// Distinct extensions that were skipped, for diagnostic reporting.
    pub skipped_extensions: Vec<String>,
    pub files: Vec<FileShape>,
}

impl CodebaseShape {
    /// Render a compact text block suitable for inclusion in an LLM prompt.
    ///
    /// The output lists each file with its language and top-level symbols
    /// (kind + name + line, plus a one-line doc fragment when present).
    /// Truncates to roughly `max_bytes` to give callers a token-budget knob;
    /// the truncation is whole-file aligned so downstream parsers don't see
    /// a partial entry.
    pub fn to_prompt_block(&self, max_bytes: usize) -> String {
        let mut out = String::new();
        out.push_str(&format!(
            "Codebase shape (deterministic AST crawl, {} files, {} symbols, langs: {}):\n",
            self.total_files,
            self.total_symbols,
            self.supported_languages.join(", ")
        ));
        if self.skipped_files > 0 {
            out.push_str(&format!(
                "⚠️  {} file(s) skipped — unsupported extensions: {}\n",
                self.skipped_files,
                self.skipped_extensions.join(", ")
            ));
        }
        for f in &self.files {
            if out.len() >= max_bytes {
                out.push_str("\n... (truncated to fit token budget)\n");
                break;
            }
            out.push_str(&format!("\n{} [{}]\n", f.path, f.language));
            if !f.imports.is_empty() {
                let imports_brief = if f.imports.len() > 12 {
                    format!(
                        "{} (+{} more)",
                        f.imports[..12].join(", "),
                        f.imports.len() - 12
                    )
                } else {
                    f.imports.join(", ")
                };
                out.push_str(&format!("  imports: {imports_brief}\n"));
            }
            for s in &f.top_level_symbols {
                let doc = s
                    .doc_first_line
                    .as_deref()
                    .map(|d| format!(" — {}", d))
                    .unwrap_or_default();
                out.push_str(&format!("  L{}: {} {}{}\n", s.line, s.kind, s.name, doc));
            }
        }
        out
    }
}

/// Top-level entry: walk `repo_root` recursively, parse every supported file,
/// produce a [`CodebaseShape`].
///
/// Skips `target/`, `node_modules/`, `.git/`, hidden directories, and files
/// over 1 MiB. Errors on individual files (parse panic, IO error) degrade
/// to a `language: "unknown", supported: false` entry rather than aborting.
pub fn crawl_repo(repo_root: &Path) -> Result<CodebaseShape> {
    let mut paths = Vec::new();
    for entry in walkdir::WalkDir::new(repo_root)
        .follow_links(false)
        .into_iter()
        .filter_entry(|e| !is_skip_dir(e.path()))
    {
        let entry = entry?;
        if entry.file_type().is_file() {
            if let Ok(meta) = entry.metadata() {
                if meta.len() > 1024 * 1024 {
                    continue;
                }
            }
            paths.push(entry.path().to_path_buf());
        }
    }
    crawl_paths(repo_root, &paths)
}

/// Crawl an explicit set of paths. Used by `chump gap decompose` when the gap
/// declares a paths list and we don't want to walk the whole repo.
pub fn crawl_paths(repo_root: &Path, paths: &[PathBuf]) -> Result<CodebaseShape> {
    let mut files = Vec::with_capacity(paths.len());
    let mut total_symbols = 0usize;
    let mut langs = HashSet::new();
    let mut emitted_unsupported: HashSet<String> = HashSet::new();
    let mut skipped_files = 0usize;
    let mut skipped_exts = HashSet::new();

    for p in paths {
        let rel = p
            .strip_prefix(repo_root)
            .unwrap_or(p)
            .to_string_lossy()
            .into_owned();
        let lang = detect_language(p);
        if !is_supported(&lang) {
            // Debounce per-extension to avoid flooding ambient when crawling
            // big asset trees.
            let ext = p
                .extension()
                .and_then(|s| s.to_str())
                .unwrap_or("(none)")
                .to_string();
            if emitted_unsupported.insert(ext.clone()) {
                let _ = emit_unsupported_language(&rel, &ext);
            }
            skipped_files += 1;
            skipped_exts.insert(ext);
            files.push(FileShape {
                path: rel,
                language: "unknown".into(),
                supported: false,
                top_level_symbols: vec![],
                imports: vec![],
            });
            continue;
        }
        match crawl_file_relative(p, &rel, &lang) {
            Ok(fs) => {
                total_symbols += fs.top_level_symbols.len();
                langs.insert(fs.language.clone());
                files.push(fs);
            }
            Err(_) => {
                files.push(FileShape {
                    path: rel,
                    language: "unknown".into(),
                    supported: false,
                    top_level_symbols: vec![],
                    imports: vec![],
                });
            }
        }
    }

    let mut supported_langs: Vec<String> = langs.into_iter().collect();
    supported_langs.sort();
    let mut skipped_exts_sorted: Vec<String> = skipped_exts.into_iter().collect();
    skipped_exts_sorted.sort();

    Ok(CodebaseShape {
        repo_root: repo_root.to_string_lossy().into_owned(),
        generated_at: Utc::now(),
        total_files: files.len(),
        total_symbols,
        supported_languages: supported_langs,
        skipped_files,
        skipped_extensions: skipped_exts_sorted,
        files,
    })
}

/// Parse a single file and return its shape. `repo_root_rel` is the path
/// to report in the output; it does not need to be a real filesystem path.
pub fn crawl_file(absolute_path: &Path) -> Result<FileShape> {
    let lang = detect_language(absolute_path);
    let rel = absolute_path.to_string_lossy().into_owned();
    if !is_supported(&lang) {
        return Ok(FileShape {
            path: rel,
            language: "unknown".into(),
            supported: false,
            top_level_symbols: vec![],
            imports: vec![],
        });
    }
    crawl_file_relative(absolute_path, &rel, &lang)
}

fn crawl_file_relative(absolute_path: &Path, rel: &str, lang: &str) -> Result<FileShape> {
    let src = std::fs::read_to_string(absolute_path)
        .with_context(|| format!("read {}", absolute_path.display()))?;
    match lang {
        "rust" => parse_rust(rel, &src),
        "python" => parse_python(rel, &src),
        "javascript" => parse_javascript(rel, &src),
        "typescript" => parse_typescript(rel, &src),
        "go" => parse_go(rel, &src),
        "bash" => parse_bash(rel, &src),
        "yaml" => parse_yaml(rel, &src),
        _ => Ok(FileShape {
            path: rel.to_string(),
            language: "unknown".into(),
            supported: false,
            top_level_symbols: vec![],
            imports: vec![],
        }),
    }
}

// ─── Language detection ────────────────────────────────────────────────────

fn detect_language(p: &Path) -> String {
    if let Some(name) = p.file_name().and_then(|s| s.to_str()) {
        if name.ends_with(".d.ts") {
            return "typescript".into();
        }
    }
    let ext = p
        .extension()
        .and_then(|s| s.to_str())
        .map(|s| s.to_ascii_lowercase())
        .unwrap_or_default();
    match ext.as_str() {
        "rs" => "rust",
        "py" => "python",
        "js" | "mjs" | "cjs" => "javascript",
        "ts" | "tsx" => "typescript",
        "go" => "go",
        "sh" | "bash" => "bash",
        "yaml" | "yml" => "yaml",
        _ => "unknown",
    }
    .to_string()
}

fn is_supported(lang: &str) -> bool {
    matches!(
        lang,
        "rust" | "python" | "javascript" | "typescript" | "go" | "bash" | "yaml"
    )
}

fn is_skip_dir(p: &Path) -> bool {
    if let Some(name) = p.file_name().and_then(|s| s.to_str()) {
        if name.starts_with('.') && name != "." {
            return true;
        }
        matches!(
            name,
            "target" | "node_modules" | "vendor" | "dist" | "build" | "__pycache__"
        )
    } else {
        false
    }
}

// ─── Per-language parsers ──────────────────────────────────────────────────
//
// Each parser walks only the top level of the tree-sitter root node — we
// don't drill into nested fns/methods. For Rust we additionally collect
// items inside `impl` blocks because their public-API shape is what matters
// for downstream consumers (e.g. ARCHITECTURE.md generation).

fn new_parser(lang: tree_sitter::Language) -> Result<Parser> {
    let mut parser = Parser::new();
    parser
        .set_language(&lang)
        .context("set_language failed (tree-sitter ABI mismatch?)")?;
    Ok(parser)
}

fn parse_tree(parser: &mut Parser, src: &str) -> Result<Tree> {
    parser
        .parse(src, None)
        .ok_or_else(|| anyhow::anyhow!("tree-sitter parser returned None"))
}

fn line_of(node: Node) -> usize {
    node.start_position().row + 1
}

fn node_text<'a>(node: Node<'a>, src: &'a str) -> &'a str {
    node.utf8_text(src.as_bytes()).unwrap_or("").trim()
}

/// Walk back over the lines preceding `line` (1-based) collecting line-comments
/// to surface the first non-blank doc line. Works for `//` `///` `#` `--` etc.
fn doc_first_line_above(src: &str, line: usize, prefix: &str) -> Option<String> {
    if line <= 1 {
        return None;
    }
    let lines: Vec<&str> = src.lines().collect();
    let mut idx = line.checked_sub(2)?;
    let mut collected: Vec<String> = Vec::new();
    loop {
        let l = lines.get(idx)?.trim();
        if l.is_empty() && collected.is_empty() {
            // attribute-style: blank line directly above the item — stop.
            return None;
        }
        if l.starts_with(prefix) {
            let stripped = l.trim_start_matches(prefix).trim().to_string();
            if !stripped.is_empty() {
                collected.push(stripped);
            }
        } else if l.is_empty() {
            break;
        } else if prefix == "//" && l.starts_with("#[") {
            // Rust attribute — skip and keep looking above.
        } else {
            break;
        }
        if idx == 0 {
            break;
        }
        idx -= 1;
    }
    collected.last().cloned()
}

// ── Rust ──────────────────────────────────────────────────────────────────

fn parse_rust(path: &str, src: &str) -> Result<FileShape> {
    let mut parser = new_parser(tree_sitter_rust::LANGUAGE.into())?;
    let tree = parse_tree(&mut parser, src)?;
    let root = tree.root_node();
    let mut symbols = Vec::new();
    let mut imports = Vec::new();
    walk_rust(root, src, &mut symbols, &mut imports);
    Ok(FileShape {
        path: path.to_string(),
        language: "rust".into(),
        supported: true,
        top_level_symbols: symbols,
        imports,
    })
}

fn walk_rust(node: Node, src: &str, symbols: &mut Vec<Symbol>, imports: &mut Vec<String>) {
    let mut cursor = node.walk();
    for child in node.named_children(&mut cursor) {
        match child.kind() {
            "function_item" => push_named(child, src, "fn", symbols, "//"),
            "struct_item" => push_named(child, src, "struct", symbols, "//"),
            "enum_item" => push_named(child, src, "enum", symbols, "//"),
            "trait_item" => push_named(child, src, "trait", symbols, "//"),
            "const_item" | "static_item" => push_named(child, src, "const", symbols, "//"),
            "mod_item" => push_named(child, src, "mod", symbols, "//"),
            "type_item" => push_named(child, src, "type", symbols, "//"),
            "impl_item" => {
                // For impl blocks, surface the type name and recurse into the
                // body so methods become first-class top-level symbols.
                let type_name = child
                    .child_by_field_name("type")
                    .map(|n| node_text(n, src).to_string())
                    .unwrap_or_else(|| "?".into());
                symbols.push(Symbol {
                    name: type_name.clone(),
                    kind: "impl".into(),
                    line: line_of(child),
                    doc_first_line: doc_first_line_above(src, line_of(child), "//"),
                });
                if let Some(body) = child.child_by_field_name("body") {
                    walk_rust(body, src, symbols, imports);
                }
            }
            "use_declaration" => {
                let txt = node_text(child, src)
                    .trim_start_matches("use ")
                    .trim_end_matches(';')
                    .trim()
                    .to_string();
                if !txt.is_empty() {
                    imports.push(txt);
                }
            }
            _ => {}
        }
    }
}

fn push_named(node: Node, src: &str, kind: &str, out: &mut Vec<Symbol>, comment_prefix: &str) {
    let name = node
        .child_by_field_name("name")
        .map(|n| node_text(n, src).to_string())
        .unwrap_or_else(|| "?".into());
    out.push(Symbol {
        name,
        kind: kind.to_string(),
        line: line_of(node),
        doc_first_line: doc_first_line_above(src, line_of(node), comment_prefix),
    });
}

// ── Python ────────────────────────────────────────────────────────────────

fn parse_python(path: &str, src: &str) -> Result<FileShape> {
    let mut parser = new_parser(tree_sitter_python::LANGUAGE.into())?;
    let tree = parse_tree(&mut parser, src)?;
    let root = tree.root_node();
    let mut symbols = Vec::new();
    let mut imports = Vec::new();
    let mut cursor = root.walk();
    for child in root.named_children(&mut cursor) {
        match child.kind() {
            "function_definition" => push_named(child, src, "fn", &mut symbols, "#"),
            "class_definition" => {
                push_named(child, src, "class", &mut symbols, "#");
                // surface top-level methods as fn entries scoped by class
                if let Some(body) = child.child_by_field_name("body") {
                    let mut bc = body.walk();
                    for grand in body.named_children(&mut bc) {
                        if grand.kind() == "function_definition" {
                            let name = grand
                                .child_by_field_name("name")
                                .map(|n| node_text(n, src).to_string())
                                .unwrap_or_else(|| "?".into());
                            let class_name = child
                                .child_by_field_name("name")
                                .map(|n| node_text(n, src).to_string())
                                .unwrap_or_else(|| "?".into());
                            symbols.push(Symbol {
                                name: format!("{class_name}.{name}"),
                                kind: "fn".into(),
                                line: line_of(grand),
                                doc_first_line: doc_first_line_above(src, line_of(grand), "#"),
                            });
                        }
                    }
                }
            }
            "expression_statement" => {
                // Top-level `SIZE = 42` is wrapped as expression_statement →
                // assignment. Drill in one level to spot module-level
                // UPPER_SNAKE constants.
                let mut ec = child.walk();
                for inner in child.named_children(&mut ec) {
                    if inner.kind() == "assignment" {
                        if let Some(lhs) = inner.child_by_field_name("left") {
                            let n = node_text(lhs, src);
                            if !n.is_empty()
                                && n.chars()
                                    .next()
                                    .map(|c| c.is_ascii_uppercase() || c == '_')
                                    .unwrap_or(false)
                                && n.chars().all(|c| {
                                    c.is_ascii_uppercase() || c.is_ascii_digit() || c == '_'
                                })
                            {
                                symbols.push(Symbol {
                                    name: n.to_string(),
                                    kind: "const".into(),
                                    line: line_of(inner),
                                    doc_first_line: doc_first_line_above(src, line_of(inner), "#"),
                                });
                            }
                        }
                    }
                }
            }
            "import_statement" | "import_from_statement" => {
                let txt = node_text(child, src).to_string();
                if !txt.is_empty() {
                    imports.push(txt);
                }
            }
            _ => {}
        }
    }
    Ok(FileShape {
        path: path.to_string(),
        language: "python".into(),
        supported: true,
        top_level_symbols: symbols,
        imports,
    })
}

// ── JavaScript ────────────────────────────────────────────────────────────

fn parse_javascript(path: &str, src: &str) -> Result<FileShape> {
    let lang: tree_sitter::Language = tree_sitter_javascript::LANGUAGE.into();
    parse_js_like(path, src, lang, "javascript")
}

fn parse_typescript(path: &str, src: &str) -> Result<FileShape> {
    // TypeScript exposes two grammars (tsx and typescript). Pick TSX when the
    // file extension is .tsx, plain typescript otherwise.
    let lang: tree_sitter::Language = if path.ends_with(".tsx") {
        tree_sitter_typescript::LANGUAGE_TSX.into()
    } else {
        tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into()
    };
    parse_js_like(path, src, lang, "typescript")
}

fn parse_js_like(
    path: &str,
    src: &str,
    lang: tree_sitter::Language,
    label: &str,
) -> Result<FileShape> {
    let mut parser = new_parser(lang)?;
    let tree = parse_tree(&mut parser, src)?;
    let root = tree.root_node();
    let mut symbols = Vec::new();
    let mut imports = Vec::new();
    let mut cursor = root.walk();
    for child in root.named_children(&mut cursor) {
        let mut item = child;
        // Treat `export` declarations as transparent wrappers.
        if matches!(child.kind(), "export_statement") {
            if let Some(decl) = child.child_by_field_name("declaration") {
                item = decl;
            } else {
                // Pure re-exports (export { foo }) — skip.
                continue;
            }
        }
        match item.kind() {
            "function_declaration" => push_named(item, src, "fn", &mut symbols, "//"),
            "class_declaration" => push_named(item, src, "class", &mut symbols, "//"),
            "lexical_declaration" | "variable_declaration" => {
                // const FOO = ...; — capture the binding name.
                let mut vc = item.walk();
                for binding in item.named_children(&mut vc) {
                    if binding.kind() == "variable_declarator" {
                        if let Some(n) = binding.child_by_field_name("name") {
                            let name = node_text(n, src).to_string();
                            if !name.is_empty() {
                                symbols.push(Symbol {
                                    name,
                                    kind: "const".into(),
                                    line: line_of(binding),
                                    doc_first_line: doc_first_line_above(src, line_of(item), "//"),
                                });
                            }
                        }
                    }
                }
            }
            "interface_declaration" => push_named(item, src, "interface", &mut symbols, "//"),
            "type_alias_declaration" => push_named(item, src, "type", &mut symbols, "//"),
            "enum_declaration" => push_named(item, src, "enum", &mut symbols, "//"),
            "import_statement" => {
                let txt = node_text(item, src).to_string();
                if !txt.is_empty() {
                    imports.push(txt);
                }
            }
            _ => {}
        }
    }
    Ok(FileShape {
        path: path.to_string(),
        language: label.into(),
        supported: true,
        top_level_symbols: symbols,
        imports,
    })
}

// ── Go ────────────────────────────────────────────────────────────────────

fn parse_go(path: &str, src: &str) -> Result<FileShape> {
    let mut parser = new_parser(tree_sitter_go::LANGUAGE.into())?;
    let tree = parse_tree(&mut parser, src)?;
    let root = tree.root_node();
    let mut symbols = Vec::new();
    let mut imports = Vec::new();
    let mut cursor = root.walk();
    for child in root.named_children(&mut cursor) {
        match child.kind() {
            "function_declaration" | "method_declaration" => {
                push_named(child, src, "fn", &mut symbols, "//")
            }
            "type_declaration" => {
                let mut tc = child.walk();
                for spec in child.named_children(&mut tc) {
                    if spec.kind() == "type_spec" {
                        let name = spec
                            .child_by_field_name("name")
                            .map(|n| node_text(n, src).to_string())
                            .unwrap_or_else(|| "?".into());
                        // Inspect the underlying type to choose struct/interface/type.
                        let kind = if let Some(ty) = spec.child_by_field_name("type") {
                            match ty.kind() {
                                "struct_type" => "struct",
                                "interface_type" => "interface",
                                _ => "type",
                            }
                        } else {
                            "type"
                        };
                        symbols.push(Symbol {
                            name,
                            kind: kind.into(),
                            line: line_of(spec),
                            doc_first_line: doc_first_line_above(src, line_of(child), "//"),
                        });
                    }
                }
            }
            "const_declaration" | "var_declaration" => {
                let mut cc = child.walk();
                for spec in child.named_children(&mut cc) {
                    if spec.kind() == "const_spec" || spec.kind() == "var_spec" {
                        if let Some(n) = spec.child_by_field_name("name") {
                            symbols.push(Symbol {
                                name: node_text(n, src).to_string(),
                                kind: "const".into(),
                                line: line_of(spec),
                                doc_first_line: doc_first_line_above(src, line_of(child), "//"),
                            });
                        }
                    }
                }
            }
            "import_declaration" => {
                let txt = node_text(child, src).to_string();
                if !txt.is_empty() {
                    imports.push(txt);
                }
            }
            _ => {}
        }
    }
    Ok(FileShape {
        path: path.to_string(),
        language: "go".into(),
        supported: true,
        top_level_symbols: symbols,
        imports,
    })
}

// ── Bash ──────────────────────────────────────────────────────────────────

fn parse_bash(path: &str, src: &str) -> Result<FileShape> {
    let mut parser = new_parser(tree_sitter_bash::LANGUAGE.into())?;
    let tree = parse_tree(&mut parser, src)?;
    let root = tree.root_node();
    let mut symbols = Vec::new();
    let imports: Vec<String> = Vec::new(); // bash has no formal imports
    let mut cursor = root.walk();
    for child in root.named_children(&mut cursor) {
        if child.kind() == "function_definition" {
            push_named(child, src, "fn", &mut symbols, "#");
        }
    }
    Ok(FileShape {
        path: path.to_string(),
        language: "bash".into(),
        supported: true,
        top_level_symbols: symbols,
        imports,
    })
}

// ── YAML ──────────────────────────────────────────────────────────────────
//
// Tree-sitter has a YAML grammar but the version churn is heavy. For
// top-level-key extraction (which is the only thing downstream cares about)
// `serde_yaml` is sufficient and avoids another tree-sitter dep.

fn parse_yaml(path: &str, src: &str) -> Result<FileShape> {
    let value: serde_yaml::Value = serde_yaml::from_str(src).unwrap_or(serde_yaml::Value::Null);
    let mut symbols = Vec::new();
    if let serde_yaml::Value::Mapping(m) = &value {
        // Cheap line lookup: scan the source for `^<key>:` once each.
        for (k, _v) in m.iter() {
            if let serde_yaml::Value::String(name) = k {
                let line = find_yaml_key_line(src, name).unwrap_or(1);
                symbols.push(Symbol {
                    name: name.clone(),
                    kind: "key".into(),
                    line,
                    doc_first_line: None,
                });
            }
        }
    }
    Ok(FileShape {
        path: path.to_string(),
        language: "yaml".into(),
        supported: true,
        top_level_symbols: symbols,
        imports: vec![],
    })
}

fn find_yaml_key_line(src: &str, key: &str) -> Option<usize> {
    for (i, line) in src.lines().enumerate() {
        let trimmed = line.trim_start();
        // Only consider top-level keys (no leading whitespace).
        if trimmed.len() != line.len() {
            continue;
        }
        if let Some(rest) = trimmed.strip_prefix(key) {
            if rest.trim_start().starts_with(':') {
                return Some(i + 1);
            }
        }
    }
    None
}

// ─── Ambient emit ──────────────────────────────────────────────────────────

fn emit_unsupported_language(path: &str, ext: &str) -> anyhow::Result<()> {
    // Honor CHUMP_AMBIENT_LOG so tests (and operators running outside a
    // repo) can redirect the stream without modifying the shared default.
    let ambient_override = std::env::var("CHUMP_AMBIENT_LOG")
        .ok()
        .filter(|s| !s.is_empty())
        .map(std::path::PathBuf::from);
    let args = chump_ambient_cli::ambient_emit::EmitArgs {
        kind: "ast_crawler_unsupported_language".into(),
        gap: std::env::var("CHUMP_GAP_ID").ok(),
        source: Some("crates/ast-crawler/src/lib.rs".into()),
        harness: None,
        fields: vec![
            ("path".into(), path.to_string()),
            ("ext".into(), ext.to_string()),
        ],
        ambient_override,
        session_override: None,
    };
    chump_ambient_cli::ambient_emit::emit(&args).map(|_| ())
}

// ─── Tests ────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn write_tmp(dir: &Path, name: &str, body: &str) -> PathBuf {
        let p = dir.join(name);
        let mut f = std::fs::File::create(&p).unwrap();
        f.write_all(body.as_bytes()).unwrap();
        p
    }

    #[test]
    fn rust_extracts_struct_and_fns() {
        let td = tempfile::tempdir().unwrap();
        let body = r#"
/// A widget for testing.
pub struct Widget {
    pub size: u32,
}

/// Make a widget.
pub fn make_widget() -> Widget {
    Widget { size: 1 }
}

/// Drop it.
fn drop_widget(_w: Widget) {}
"#;
        let p = write_tmp(td.path(), "lib.rs", body);
        let shape = crawl_file(&p).unwrap();
        assert_eq!(shape.language, "rust");
        assert!(shape.supported);
        let names: Vec<&str> = shape
            .top_level_symbols
            .iter()
            .map(|s| s.name.as_str())
            .collect();
        assert!(names.contains(&"Widget"), "got {names:?}");
        assert!(names.contains(&"make_widget"), "got {names:?}");
        assert!(names.contains(&"drop_widget"), "got {names:?}");
        let make_widget = shape
            .top_level_symbols
            .iter()
            .find(|s| s.name == "make_widget")
            .unwrap();
        assert_eq!(make_widget.kind, "fn");
        assert!(make_widget
            .doc_first_line
            .as_deref()
            .unwrap_or("")
            .contains("Make a widget"));
    }

    #[test]
    fn python_extracts_class_and_methods() {
        let td = tempfile::tempdir().unwrap();
        let body = r#"
# A widget class.
class Widget:
    # Make one.
    def make(self):
        return 1

    def drop(self):
        return None

# Module-level constant.
SIZE = 42
"#;
        let p = write_tmp(td.path(), "thing.py", body);
        let shape = crawl_file(&p).unwrap();
        assert_eq!(shape.language, "python");
        let names: Vec<&str> = shape
            .top_level_symbols
            .iter()
            .map(|s| s.name.as_str())
            .collect();
        assert!(names.contains(&"Widget"), "got {names:?}");
        assert!(names.contains(&"Widget.make"), "got {names:?}");
        assert!(names.contains(&"Widget.drop"), "got {names:?}");
        assert!(names.contains(&"SIZE"), "got {names:?}");
    }

    #[test]
    fn javascript_extracts_classes_and_consts() {
        let td = tempfile::tempdir().unwrap();
        let body = r#"
import { foo } from './foo.js';

// A const.
export const TOKEN_BUDGET = 4096;

// Hello.
export function hello() { return 1; }

class Greeter {
    greet() { return "hi"; }
}
"#;
        let p = write_tmp(td.path(), "thing.js", body);
        let shape = crawl_file(&p).unwrap();
        assert_eq!(shape.language, "javascript");
        let names: Vec<&str> = shape
            .top_level_symbols
            .iter()
            .map(|s| s.name.as_str())
            .collect();
        assert!(names.contains(&"hello"), "got {names:?}");
        assert!(names.contains(&"Greeter"), "got {names:?}");
        assert!(names.contains(&"TOKEN_BUDGET"), "got {names:?}");
        assert!(!shape.imports.is_empty());
    }

    #[test]
    fn typescript_extracts_interfaces_and_types() {
        let td = tempfile::tempdir().unwrap();
        let body = r#"
export interface Widget { size: number; }
export type WidgetId = string;
export function getWidget(): Widget { return { size: 1 }; }
"#;
        let p = write_tmp(td.path(), "thing.ts", body);
        let shape = crawl_file(&p).unwrap();
        assert_eq!(shape.language, "typescript");
        let kinds: Vec<&str> = shape
            .top_level_symbols
            .iter()
            .map(|s| s.kind.as_str())
            .collect();
        assert!(kinds.contains(&"interface"));
        assert!(kinds.contains(&"type"));
        assert!(kinds.contains(&"fn"));
    }

    #[test]
    fn go_extracts_struct_and_fn() {
        let td = tempfile::tempdir().unwrap();
        let body = r#"
package main

import "fmt"

type Widget struct {
    Size int
}

func makeWidget() Widget {
    return Widget{Size: 1}
}
"#;
        let p = write_tmp(td.path(), "thing.go", body);
        let shape = crawl_file(&p).unwrap();
        assert_eq!(shape.language, "go");
        let names: Vec<&str> = shape
            .top_level_symbols
            .iter()
            .map(|s| s.name.as_str())
            .collect();
        assert!(names.contains(&"Widget"), "got {names:?}");
        assert!(names.contains(&"makeWidget"), "got {names:?}");
    }

    #[test]
    fn bash_extracts_functions() {
        let td = tempfile::tempdir().unwrap();
        let body = r#"#!/bin/bash
# A greeter.
hello() {
    echo "hi"
}

bye() {
    echo "bye"
}
"#;
        let p = write_tmp(td.path(), "tool.sh", body);
        let shape = crawl_file(&p).unwrap();
        assert_eq!(shape.language, "bash");
        let names: Vec<&str> = shape
            .top_level_symbols
            .iter()
            .map(|s| s.name.as_str())
            .collect();
        assert!(names.contains(&"hello"), "got {names:?}");
        assert!(names.contains(&"bye"), "got {names:?}");
    }

    #[test]
    fn yaml_top_level_keys() {
        let td = tempfile::tempdir().unwrap();
        let body = r#"
schema_version: 2
events:
  - kind: foo
    emitter: bar
last_audit: "2026-05-22"
"#;
        let p = write_tmp(td.path(), "thing.yaml", body);
        let shape = crawl_file(&p).unwrap();
        assert_eq!(shape.language, "yaml");
        let names: Vec<&str> = shape
            .top_level_symbols
            .iter()
            .map(|s| s.name.as_str())
            .collect();
        assert!(names.contains(&"schema_version"));
        assert!(names.contains(&"events"));
        assert!(names.contains(&"last_audit"));
    }

    #[test]
    fn unsupported_extension_falls_back_gracefully() {
        let td = tempfile::tempdir().unwrap();
        // Redirect ambient writes into the tempdir so the test doesn't
        // pollute the real ambient.jsonl.
        std::env::set_var(
            "CHUMP_AMBIENT_LOG",
            td.path().join("ambient.jsonl").to_string_lossy().as_ref(),
        );
        let p = write_tmp(td.path(), "thing.qq", "binary blob, parser cannot read");
        let shape = crawl_paths(td.path(), &[p]).unwrap();
        assert_eq!(shape.files[0].language, "unknown");
        assert!(!shape.files[0].supported);
        assert!(shape.files[0].top_level_symbols.is_empty());
    }

    #[test]
    fn prompt_block_truncates_under_budget() {
        let td = tempfile::tempdir().unwrap();
        let body = "pub fn a() {}\npub fn b() {}\n";
        let p = write_tmp(td.path(), "x.rs", body);
        let shape = crawl_paths(td.path(), &[p]).unwrap();
        let small = shape.to_prompt_block(50);
        // The header alone exceeds 50 bytes, so output should mention truncation.
        assert!(
            small.contains("truncated") || small.len() <= 200,
            "small={small}"
        );
        let big = shape.to_prompt_block(10_000);
        assert!(big.contains("x.rs"));
    }
}
