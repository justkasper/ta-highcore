---
name: dbt-docs
description: Format and review dbt YAML documentation — model/source/column descriptions, `meta:` blocks, doc blocks (`{% docs %}`), tags. Trigger on edits to `_models.yml`, `sources.yml`, `schema.yml`, or `{% docs %}` blocks; on requests to "document a dbt model", "describe columns", "clean up dbt docs", "write descriptions for"; or when prepared materials (EDA notes, draft descriptions, research markdown) need turning into dbt YAML. Do NOT use for writing dbt model SQL, configuring `dbt_project.yml`, designing tests, performing EDA on raw data, or debugging `dbt run` failures.
---

# dbt documentation

Formats and reviews dbt documentation. Inputs are notes, drafts, and existing artifacts. Outputs are clean YAML, with gaps marked **in the YAML itself** so they're discoverable via `dbt ls --select tag:check`.

**Does:** lay out prepared materials as structured YAML; review existing YAML and mark gaps; migrate Markdown research into doc blocks.

**Does not:** investigate data, invent semantics, add or modify tests, change SQL files, or write model SQL — defer to the `using-dbt-for-analytics-engineering` skill for model code.

**The single rule:** when inputs are insufficient, mark the gap in the YAML — don't guess, don't omit.

**Idempotency:** if a node already has all four blocks, no `[CHECK]` lines, no name-restating descriptions, and no missing column semantics, leave it alone. Re-running the skill should produce zero diffs on already-clean YAML.

> **Read `references/examples.md` with the Read tool** before producing any non-trivial YAML — it's the canonical pattern source (complete `_models.yml`, source with all fields, gap-marked version). Copy structures from it rather than assembling from memory.

## Audience: agents and humans both

dbt YAML is read by humans (PRs, `dbt docs`) and by agents (LLM tools that pick models, write SQL). Failure modes differ:

- Humans tolerate vague phrasing — they ask in Slack. Agents act on what's written.
- Humans infer that `total_amount` is in the home currency. Agents silently sum EUR and USD.
- Humans read prose. Agents pattern-match on labels (`ROLE:`, `GRAIN:`, `USE WHEN:`).

Documentation explicit enough for an agent is also better for new humans. The reverse is not true.

## The `check` mechanism

For every gap, inconsistency, or missing piece, do **both**:

1. Add `check` to the node's tags (syntax differs by level — see below).
2. Add a `[CHECK] ...` line in `description:` stating the specific question.

`[CHECK]` lines are imperative and specific. Bad: `[CHECK] needs more info`. Good: `[CHECK] Timezone of event_at — UTC or local? Server-side or user-side?`

Resolution: user answers, removes the `[CHECK]` line, removes the `check` tag. CI can fail on `dbt ls --select tag:check`.

### Tag syntax — get this right

```yaml
# MODEL — must be inside config:
models:
  - name: fct_orders
    config:
      tags: ["check"]

# SOURCE / SOURCE TABLE / COLUMN — top-level tags:
sources:
  - name: raw_crm
    tags: ["check"]
    tables:
      - name: accounts
        tags: ["check"]
        columns:
          - name: id
            tags: ["check"]
```

Bare `tags:` at model level (without `config:`) is silently dropped in many dbt versions. Always wrap model-level tags in `config:`.

**Selector caveat.** `dbt ls --select tag:check` finds models, sources, source tables — **not columns**. If only columns have checks, also tag the model itself so it surfaces in the selector.

## Core principle: describe why, not what

Names already say *what*. Descriptions exist to say *why this exists*, *when to use it*, *what will surprise you*, *what the values mean*.

A name-restating description (`customer_id: "the customer ID"`) is worse than no description — it occupies the slot where useful info should be. Treat such inputs as placeholders that need a `check`.

## Required structure for every model and source

Four labeled blocks. Same labels everywhere — agents pattern-match on them.

1. **Triggers** — `ROLE:`, `USE WHEN:`, `DON'T USE FOR:`
2. **Grain & relationships** — `GRAIN:`, `PK:`, `FK:`, `DOWNSTREAM:`
3. **Column semantics** — per-column unit / currency / timezone / NULL meaning (in each column's description)
4. **Edge cases** — `EDGE CASES:`

If a block's content is missing from the input, write the block with `[CHECK]` rather than omitting it. Absent ≠ "nothing to say" — `[CHECK]` is informative, silence is ambiguous.

For edge cases specifically, when there are genuinely none, write `"None known as of <date>"` — silence is ambiguous (was it checked? forgotten?).

### What to capture per column type

- **Numbers**: unit, currency, scale, sign convention, tax/discount inclusion
- **Timestamps**: timezone, source-of-truth (server time? user-local? when written?)
- **Strings**: enum values; case sensitivity; trimming
- **NULL**: when it occurs, what it means (missing? not-applicable? legacy?)

Don't assume "probably USD" or "probably UTC". Mark with `check`.

### Existing tests are signal, not target

When reviewing, read existing tests as hints:
- `unique` + `not_null` → it's the PK
- `relationships` → it's an FK, target is in the test config

Use those signals to phrase descriptions. Never add or remove tests.

## What goes in `meta:`

Machine-readable attributes only — `owner`, `pii`, `business_domain`, `status`. Anything a human reads goes in `description:`.

A `meta:` field can sit alongside a description that explains the same thing in human terms (e.g. `meta.status: unused` + a description saying so). That's not duplication — it's the same fact in two registers (machine handle + human reader).

**But:** if a fact is already expressed structurally (`meta.owner`, `loader:`, `freshness:`), don't restate it in `description:` prose. Description is for semantics that structure can't express.

```yaml
# bad — prose belongs in description, not meta
meta:
  notes: "Order-grain fact, owned by analytics-eng"

# good — meta holds machine handles, description holds prose
meta:
  owner: analytics-eng
  business_domain: orders
description: |
  ROLE: Order-grain fact table. One row per order_id.
  ...
```

## Unused / legacy fields

Three patterns by volume:

- **≤5 fields**: tag the column itself (`tags: ["unused"]`, `meta.status: unused`).
- **5–30 fields**: doc block with a table, referenced from the parent description.
- **30+ fields or whole deprecated subsystem**: separate `_deprecated.md` doc block.

Never leave an unused column undocumented. Minimum: column name + `tags: ["unused"]`.

See `references/examples.md` for the doc-block table pattern.

## Migrating long Markdown research → doc blocks

dbt has no "research document" object, but doc blocks render as full Markdown pages in `dbt docs`.

Layout:
```
models/staging/crm/
├── _crm__sources.yml
├── _crm__models.yml
└── _crm__overview.md      ← long-form research
```

Split `_crm__overview.md` into named `{% docs %}` blocks (`<source>__<topic>`) so sections can be referenced independently from individual `description:` fields. Don't dump the whole file into one description.

**Too big for dbt docs** (50+ pages, diagrams): keep long version in `/docs` or Confluence/Notion, put a short summary + link in the doc block. Agents load the whole block into context every time.

## YAML is the source of truth, not SQL comments

Descriptions live in YAML. Don't duplicate in SQL comments — they drift, and YAML is the only place every consumer (`dbt docs`, dbt-MCP, IDE plugins, BI catalogues) reads.

SQL comments are for code-level notes only: implementation rationale, ticket refs, warnings about intentional weirdness, pointer to the docs.

When reviewing: if a `.sql` file has a long header comment explaining what the model is, mark the YAML node with `check` and ask to move it.

## Style rules

- **Direct, not hedged or narrative.** "Filter `status='test'` rows for business metrics." — not "you should probably filter test rows" and not "we filter test rows because the QA team writes there".
- **Consistent labels** across all files: `ROLE:`, `GRAIN:`, `PK:`, `FK:`, `USE WHEN:`, `DON'T USE FOR:`, `EDGE CASES:`, `DOWNSTREAM:`, `[CHECK]`.
- **One concept, one term.** If input mixes "users" / "customers", pick one and `[CHECK]` the inconsistency.
- **Date everything that changed.** "Before 2023-01-15…" — not "recently…".
- **Quantify when possible.** "~3% of rows" beats "some rows".

## Version notes

- `version: 2` — optional in dbt 1.5+; targeted for removal in dbt 2.0 (no firm date as of 2026-04). Keep if present, omit in new files.
- `data_tests:` — dbt 1.8+ keyword; earlier versions use `tests:`. Match the project; don't migrate as a side effect.
- Model-level `tags:` must be inside `config:` (see above).

## Review checklist

For each "no" → add `check` tag (`config: { tags: ["check"] }` for models, top-level elsewhere) + `[CHECK]` line in description. Don't fabricate fixes.

**Per model/source:**
1. All four blocks present (Triggers, Grain & relationships, Column semantics, Edge cases)?
2. `GRAIN` stated in one sentence, unambiguous?
3. Similarly-named models distinguished in `DON'T USE FOR`?
4. `EDGE CASES` present? (Empty → `check` with the "None known as of <date>" prompt.)

**Per column:**
5. Any description merely restates the column name?
6. Numerics: unit / currency / scale stated?
7. Timestamps: timezone and source-of-truth stated?
8. Enums: allowed values listed with meanings?
9. NULL semantics explained where NULLs occur?

**Cross-cutting:**
10. One concept named one way throughout?
11. Unused/legacy columns at least tagged `unused`?
12. Sources: loader, freshness, owner present?
13. Descriptions duplicated in `.sql` headers? (`check` to move them.)
14. Structural facts (owner, loader, freshness) duplicated in description prose? (Remove the prose copy.)

**Output of a review is the YAML itself**, with `check` tags and `[CHECK]` lines. Chat summary is fine; the file is the source of truth.
