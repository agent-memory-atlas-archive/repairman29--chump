# chump-store-path

The one resolver for where the Chump gap store (`state.db`) lives
(INFRA-8190, Phase R R4 "one canonical store").

Precedence, identical in Rust (this crate) and shell
(`scripts/coord/lib/state-store.sh`):

1. `CHUMP_STATE_DB`, if set and non-empty (a leading `~` expands to `$HOME`).
2. The git checkout containing the root: `<main checkout>/.chump/state.db`.
   A linked worktree (whose `.git` is a file) resolves to its **main**
   checkout's store, never a per-worktree copy.
3. No checkout above the root: `<root>/.chump/state.db`. When the root is
   `$HOME` this is the legacy `~/.chump/state.db`, and a one-line warning is
   printed to stderr (once per process).

`CHUMP_STATE_DIR` is deliberately **not** consulted: it is the node-state
directory (`providers.env`, `node.env`, heartbeats), not a store selector.

Operators: `chump gap store-path [--json]` prints the resolved path and why.
