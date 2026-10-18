# events.d — per-entry event-registry fragments (RESILIENT-1618)

GitHub's server-side merge (mergeability, **update-branch**, and the merge
itself) **never runs local merge drivers**, so the `merge=union` attribute on
`docs/observability/EVENT_REGISTRY.yaml` does not help on the server. Two armed
PRs that each append one `- kind:` entry to that monolith always conflict after
the first lands, and `update-branch` — the only sanctioned unstick — cannot heal
it (it would need the union driver GitHub refuses to run).

**Fix: new event kinds land here, one entry per file.** A PR that registers a
kind creates a brand-new file `events.d/<kind>.yaml`. Two such PRs never touch a
shared file, so GitHub's merge is conflict-free and `update-branch` just works —
no merge driver, no human push.

## Fragment format

One file per kind, named `<kind>.yaml` (filename stem **must** equal the declared
`kind`). The body is a single YAML list item at 2-space indent, identical in
shape to an entry in the `events:` list of the monolith:

```yaml
  - kind: my_new_kind
    effect_metric: self
    emitter: src/foo.rs
    trigger: >-
      when the thing happens
    consumers: [fleet-brief]
    fields_required: [ts, kind]
```

## The complete registry

Consumers that need the full picture read the **generated** concatenation of the
frozen monolith base + every fragment here, via:

```bash
scripts/ci/gen-registries.sh events   # prints base + sorted fragments to stdout
```

The monolith `EVENT_REGISTRY.yaml` stays committed as the frozen base (all
pre-existing kinds); nothing re-sorts or rewrites it, so existing readers keep
working unchanged. New kinds accrete here as fragments.

## Gates

- `scripts/ci/test-registry-fragments.sh` — freshness/validity: filename==kind,
  no duplicate kind across base+fragments, generated registry parses under
  PyYAML.
- `scripts/ci/test-registry-fragment-no-conflict.sh` — proves two fragment PRs
  land in sequence via `update-branch` with zero conflicts.

## Reader migration status (RESILIENT-1618 slice 1)

The census found >5 readers of the monolith, so per the gap's slice-1 rule only
the generator + the two CI coverage gates (`test-event-registry-coverage.sh`,
`test-env-var-coverage.sh`) + the pre-commit event-registry hook were migrated
to read base+fragments here. Remaining readers (the `chump emit-event` writer,
the Rust `verify` rule, and ~200 incidental consumers) are tracked as follow-up
in the RESILIENT-1618 gap notes.
