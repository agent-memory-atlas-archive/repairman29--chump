---
doc_tag: canonical
owner_gap: EFFECTIVE-1900
last_audited: 2026-09-29
---

# Design-pass stage specification (EFFECTIVE-358 slice)

This is the formal spec for the design-pass stage — factory L3 (design:
UI/brand/interaction), per `docs/strategy/SOFTWARE_FACTORY_MATRIX_2026-08-05.md`
§3. The full process narrative (rationale, heuristic checklist, worked
hand-off table) lives in `docs/design-pass-stage.md` (EFFECTIVE-827); this
document is the short-form spec that AC1/AC2 of EFFECTIVE-1900 require at a
stable path: inputs, outputs, and hand-off artifacts.

## Inputs (intake requirements)

The design pass activates only when an intake-produced gap or umbrella
description names a **user-facing surface** (CLI with interactive output,
web UI, PWA view, dashboard) rather than a pure library/API/backend change.
Its inputs are:

1. **Intake requirement set** — `chump intake`'s structured output: user
   stories, restatement, detected entities/constraints/risks
   (`src/vision_intake.rs`, EFFECTIVE-357).
2. **Existing brand tokens**, if any — a
   `docs/schemas/brand-tokens.schema.json`-conformant file for the product
   (EFFECTIVE-636).
3. **Canonical CSS token vocabulary** —
   `docs/process/CSS_TOKEN_DISCIPLINE.md`'s 11 color tokens + 2 radius
   tokens. The design pass works within this vocabulary; it does not invent
   new token names.

## Outputs (UI/brand/interaction spec)

A short written spec — attached to the umbrella gap as a note, or a
`docs/design-specs/<product>.md` file for anything non-trivial — covering:

1. **Layout** — primary views/screens and their arrangement.
2. **Brand tokens** — a `brand-tokens.schema.json`-conformant mapping of the
   product's palette onto canonical token names, reusing the default PWA
   tokens (`web/v2/index.html` `:root`) unless the product has a distinct
   brand.
3. **Interaction** — key user actions and their idle/loading/success/error
   states, with the canonical token each state uses.
4. **Heuristic checklist result** — pass/fail against the fixed checklist in
   `docs/design-pass-stage.md` §The heuristic checklist.

## Hand-off artifacts

| From | To | Artifact |
|---|---|---|
| Intake (`chump intake`) | Design pass | Structured requirement set |
| Design pass | Implement stage (fleet worker claiming the gap) | UI/brand/interaction spec (this doc's Outputs section) |
| Implement stage | CSS token discipline gate (INFRA-1590) | Committed code — mechanical enforcement, independent of whether a design pass ran |
| Design pass | Design chair + engineering lead (review) | This spec, for approval before implement work is dispatched |

The design pass does not replace INFRA-1590; it is the upstream half
(deciding what the UI should look like) that the gate's downstream token
enforcement assumes already happened.

## Approval

- **Design chair:** approved 2026-09-08 as part of `docs/design-pass-stage.md`
  (EFFECTIVE-827) — the input/output/hand-off shape defined there and
  restated here matches the L3 stage named in
  `SOFTWARE_FACTORY_MATRIX_2026-08-05.md`.
- **Engineering lead:** approved — the hand-off boundary to the implement
  stage and the CSS token discipline gate (INFRA-1590) as the mechanical
  enforcement layer is consistent with existing gate behavior; no new
  enforcement code is implied by this spec.
