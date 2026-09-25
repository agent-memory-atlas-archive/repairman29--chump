//! INFRA-1748 pilot infrastructure (INFRA-5754 slice): the self-registration
//! interface + `inventory`-backed lookup that lets a CLI subcommand register
//! itself from wherever it's defined instead of adding another
//! `args.get(1) == Some("<name>")` block to the dispatch chain in
//! `src/main.rs`. See `docs/refactor/MAIN_RS_DECOMPOSITION.md` for the full
//! migration map — this slice only lands the interface; no subcommand has
//! been ported to it yet.

/// Outcome of a self-registered subcommand handler.
pub type CommandOutcome = anyhow::Result<()>;

/// One self-registered CLI subcommand: the name matched against `args[1]`
/// and the handler invoked with the full `args` vector (same calling
/// convention as the existing `args.get(1) == Some("<name>")` blocks).
pub struct CommandEntry {
    pub name: &'static str,
    pub handler: fn(&[String]) -> CommandOutcome,
}

impl CommandEntry {
    /// Register a subcommand. `name` is matched against `args[1]`; `handler`
    /// receives the full `args` vector, same as the legacy dispatch blocks.
    pub const fn new(name: &'static str, handler: fn(&[String]) -> CommandOutcome) -> Self {
        Self { name, handler }
    }
}

inventory::collect!(CommandEntry);

/// Find the self-registered entry matching `name` (i.e. `args.get(1)`), if any.
pub fn lookup(name: &str) -> Option<&'static CommandEntry> {
    inventory::iter::<CommandEntry>().find(|entry| entry.name == name)
}

/// Dispatch to a self-registered subcommand matching `name`. Returns `None`
/// when nothing is registered under that name so callers (main.rs's legacy
/// dispatch chain) can fall through unchanged during the migration.
pub fn dispatch(name: &str, args: &[String]) -> Option<CommandOutcome> {
    lookup(name).map(|entry| (entry.handler)(args))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lookup_returns_none_when_unregistered() {
        assert!(lookup("definitely-not-a-registered-command-xyz").is_none());
    }

    #[test]
    fn dispatch_returns_none_when_unregistered() {
        assert!(dispatch("definitely-not-a-registered-command-xyz", &[]).is_none());
    }
}
