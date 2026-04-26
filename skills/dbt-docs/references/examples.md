# dbt-docs: examples

Full canonical examples. Read this before producing any non-trivial YAML — copy these structures rather than assembling fragments by hand.

## Contents

- [Complete `_models.yml`](#complete-_modelsyml)
- [Same model with gaps marked](#same-model-with-gaps-marked)
- [Source with all fields](#source-with-all-fields)
- [Per-block examples](#per-block-examples)
- [Unused-fields doc block](#unused-fields-doc-block)
- [Research doc block](#research-doc-block)

---

## Complete `_models.yml`

```yaml
version: 2  # optional in dbt 1.5+; keep if present, omit in new files

models:
  - name: fct_orders
    description: |
      ROLE: Order-grain fact table. One row per order_id.
      USE WHEN: Order-level metrics — count, AOV, conversion, status funnel.
      DON'T USE FOR: Line-item analysis (use `fct_order_items`); revenue accounting (use `fct_revenue`).

      GRAIN: One row per order_id.
      PK: order_id
      FK: customer_id → dim_customers.customer_id (NULL for guest checkouts, ~3% of rows)
          promotion_id → dim_promotions.promotion_id (NULL when no promo)
      DOWNSTREAM: rpt_revenue_daily, rpt_cohorts, fct_clv

      EDGE CASES:
        - status='test' rows are QA traffic — filter for business metrics.
        - Before 2023-01-15 `currency` was NULL; treat NULL as EUR for that period.
        - Backfill 2024-03-02 to 2024-03-04 is excluded via the `_is_valid` filter.
    meta:
      owner: analytics-eng
      business_domain: orders
    columns:
      - name: order_id
        description: PK. Surrogate key from the order service.

      - name: customer_id
        description: FK to dim_customers. NULL for guest checkouts (~3% of rows).

      - name: total_amount
        description: |
          Order total in EUR, INCLUDING VAT and discounts, EXCLUDING shipping.
          Cancelled orders carry the original amount — use `status` to filter.
          For multi-currency convert via `dim_fx_rates`.

      - name: status
        description: |
          Order lifecycle state. Filter status='test' for business metrics.

      - name: event_at
        description: Server-side timestamp in UTC, set by the API gateway when the request is acknowledged (not user click time).
```

Existing `data_tests:` (or `tests:` in pre-1.8 dbt) sit under each column — preserve, don't add.

## Same model with gaps marked

When inputs are partial — missing pieces aren't omitted, they're marked. Note `config:` wrapper for model-level tags.

```yaml
version: 2

models:
  - name: fct_orders
    config:
      tags: ["check"]
    description: |
      ROLE: Order-grain fact table.
      GRAIN: One row per order_id.
      USE WHEN: Order-level metrics.
      DON'T USE FOR: [CHECK] What other order-related models exist (line items, revenue, returns)?

      PK: order_id
      FK: customer_id → dim_customers.customer_id
      DOWNSTREAM: [CHECK] Which downstream models depend on this? Run `dbt ls --select fct_orders+ --resource-type model` to find them.

      EDGE CASES:
        [CHECK] No edge cases provided. Historical regime changes, broken backfills, test rows? If genuinely none, replace with "None known as of <date>."
    meta:
      owner: analytics-eng
    columns:
      - name: total_amount
        description: |
          Order total.
          [CHECK] Currency, VAT inclusion, shipping inclusion, NULL semantics — none specified in input.
        tags: ["check"]

      - name: event_at
        description: |
          Event timestamp.
          [CHECK] Timezone? Source-of-truth (server vs client)?
        tags: ["check"]
```

## Source with all fields

```yaml
version: 2

sources:
  - name: raw_crm
    description: |
      Salesforce CRM export — see {{ doc('raw_crm__overview') }} for known issues and history.
    database: raw
    schema: salesforce
    loader: fivetran
    loaded_at_field: _fivetran_synced
    freshness:
      warn_after: {count: 1, period: hour}
      error_after: {count: 6, period: hour}
    meta:
      owner: data-platform
      pii: true
      business_domain: sales

    tables:
      - name: accounts
        description: |
          GRAIN: One row per Salesforce account_id (active OR soft-deleted).
          PK: id
          USE WHEN: Need raw account attributes; for analytics prefer `dim_accounts`.
          EDGE CASES:
            - is_deleted=true rows are soft-deletes, not physical deletes — filter for active set.
            - 'sandbox' org_type rows are test data from Salesforce sandboxes.
        columns:
          - name: id
            description: PK. UUID assigned by Salesforce.
```

Note what's **not** in the description: owner, loader, freshness cadence — those are structural fields. Don't restate.

## Per-block examples

### Block 1: Triggers

```yaml
description: |
  ROLE: Order-grain fact table. One row per order_id.
  USE WHEN: Order-level metrics — count, AOV, conversion, status funnel.
  DON'T USE FOR: Line-item analysis (use `fct_order_items`); revenue accounting (use `fct_revenue` — handles refunds and FX).
```

### Block 2: Grain & relationships

```yaml
description: |
  GRAIN: One row per order_id.
  PK: order_id
  FK: customer_id → dim_customers.customer_id (NULL for guest checkouts, ~3% of rows)
      promotion_id → dim_promotions.promotion_id (NULL when no promo)
  DOWNSTREAM: rpt_revenue_daily, rpt_cohorts, fct_clv (changes here ripple to all three)
```

### Block 3: Column semantics

```yaml
- name: total_amount
  description: Order total in EUR, INCLUDING VAT and discounts, EXCLUDING shipping. Cancelled orders carry the original amount — use `status` to filter. For multi-currency convert via `dim_fx_rates`.

- name: event_at
  description: Server-side timestamp in UTC. Written by the API gateway when the request is acknowledged, not when the user clicked.

- name: status
  description: |
    Order lifecycle state. Values:
      - 'draft'      — created, not paid
      - 'paid'       — payment confirmed
      - 'shipped'    — handed to carrier
      - 'delivered'  — final positive state
      - 'cancelled'  — final negative state
      - 'test'       — QA traffic, ALWAYS filter out for business metrics
```

### Block 4: Edge cases

```yaml
description: |
  EDGE CASES:
    - Rows with status='test' are QA traffic — filter for business metrics.
    - Before 2023-01-15 the `currency` column was NULL; treat NULL as EUR for that period.
    - Backfill on 2024-03-02 to 2024-03-04 is known-bad (duplicate event_ids), excluded via the `_is_valid` filter.
    - Guest checkouts have customer_id = NULL — do not inner-join to dim_customers without explicit handling.
```

When input has nothing on edge cases:

```yaml
description: |
  EDGE CASES:
    [CHECK] No edge cases provided. Historical regime changes, broken backfill periods, test/QA rows, deprecated values? If genuinely none, replace with "None known as of <date>."
```

## Unused-fields doc block

For 5–30 trivial unused fields — create a `.md` file next to the YAML:

```markdown
{% docs raw_crm__accounts__legacy_fields %}
## Unused columns in raw_crm.accounts

| Column | Original purpose | Reason not used |
|--------|------------------|-----------------|
| legacy_account_code | Pre-2022 CRM code | Replaced by `id` |
| old_status          | Pre-v2 status     | Replaced by `status_v2` |
| sfdc_internal_xyz   | Salesforce metadata | Not business-meaningful |
{% enddocs %}
```

Reference from the table description:

```yaml
- name: accounts
  description: |
    ...main description...
    UNUSED COLUMNS: see {{ doc('raw_crm__accounts__legacy_fields') }}
  tags: ["unused", "legacy"]
```

For ≤5 fields, tag the column directly:

```yaml
- name: legacy_account_code
  description: Pre-2022 account code from the old CRM. Not used downstream. Kept for audit lookups.
  meta:
    status: unused
    reason: legacy_pre_2022_migration
  tags: ["unused", "legacy"]
```

## Research doc block

`_crm__overview.md` — split into named blocks so sections can be referenced independently:

```markdown
{% docs raw_crm__overview %}
# CRM source overview

## History
The current Salesforce instance replaced the legacy MS Dynamics CRM in February 2022...

## Known data quirks
- Accounts created during the migration window (2022-02-10 to 2022-02-16) have...
- The `industry` field was free-text until 2023-Q2, then became a picklist...

## Business rules
- An account is "active" if `status_v2 IN ('customer', 'opportunity')` AND `is_deleted = false`...
{% enddocs %}

{% docs raw_crm__accounts__grain %}
GRAIN: One row per Salesforce account_id, including soft-deleted rows.
{% enddocs %}
```

Reference from source YAML:

```yaml
sources:
  - name: raw_crm
    description: "{{ doc('raw_crm__overview') }}"
```
