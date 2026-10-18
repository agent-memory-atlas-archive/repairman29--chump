# env-vars.d — per-entry internal-env-var registry fragments (RESILIENT-1618)

Same problem and fix as `docs/observability/events.d/` (read that README first):
GitHub never runs local merge drivers, so the `merge=union` attribute on
`scripts/ci/env-vars-internal.txt` is a no-op on the server. Two armed PRs that
each append one var to the monolith conflict after the first lands and
`update-branch` cannot heal it.

**Fix: new internal env vars land here, one var per file.** A PR that registers
`FOO_BAR` creates a brand-new file `env-vars.d/FOO_BAR`. New files never collide,
so the merge is conflict-free.

## Fragment format

One file per var, named exactly `<VAR>` (filename **must** equal the var name).
The body is the var name on its own line (comments above it are allowed):

```
# gap: RESILIENT-1618
FOO_BAR
```

## The complete list

Readers that need every internal var read the generated concatenation:

```bash
scripts/ci/gen-registries.sh env-vars   # prints base + sorted fragments
```

The monolith `env-vars-internal.txt` stays the committed frozen base; new vars
accrete here. See the events.d README for gates and reader-migration status.
