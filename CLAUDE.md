# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project context

This is a take-home assignment for an Analytics Engineer role at Highcore. The full spec is in `TEST_ASSIGNMENT.md` (Russian); the product ask is to build cohort retention + early-days monetization views over a public Firebase Analytics export from a mobile F2P game ("Flood-It!"). Deliverables land in this repo:

- dbt models under `models/staging/`, `models/intermediate/`, `models/marts/`
- Free-form data exploration writeup at `docs/data_exploration.md`
- One reusable skill at `skills/<name>/SKILL.md`
- An updated `README.md` covering decisions, assumptions, trade-offs, and an Airflow orchestration sketch

The assignment text is Russian, but model SQL, tests, and docs can be written in either language.

## Following the spec

`TEST_ASSIGNMENT.md` is the literal source of truth for deliverables — file paths, formats, scope. Default to following it verbatim: write into the exact paths it names and cover the sections it asks for. Don't invent parallel deliverables next to those the spec already names.

When a tool or skill produces output that doesn't fit the spec's shape (e.g. a structured discovery report when Part 1 asks for a free-form one), **fold it into the named artifact** rather than creating a sibling file. Concrete example: Part 1 names `docs/data_exploration.md` as the single artifact — the comprehensive EDA lives there, with any structured by-products consolidated in. Auxiliary notes (e.g. `docs/eda_report.md`, `docs/eda_tests.md`) are fine as supporting material, but the named deliverable must always exist at the spec's path and cover what the spec asks for.

At minimum, every action should be grounded in the spec rather than improvised. If a decision deviates from it (trade-offs, scope cuts), record the deviation explicitly in `README.md` per Part 6.

## Common commands

| Command | What it does |
| --- | --- |
| `make setup` | Installs Python deps and runs `scripts/prepare_data.py` (downloads ~500 MB parquet from Google Drive, loads into `raw.events`). |
| `make build` | Runs `dbt build` (run + test for everything). |
| `make docs` | `dbt docs generate` + `dbt docs serve` on `localhost:8080`. |
| `make clean` | Wipes `target/`, `dbt_packages/`, `logs/`, and the local DuckDB + parquet under `data/`. |

Single-model workflow: `dbt run --select <model>`, `dbt test --select <model>`, `dbt build --select +<model>+`.

`DBT_PROFILES_DIR` is set to the repo root by the `Makefile`. When running `dbt` outside `make`, export it (`export DBT_PROFILES_DIR=.`) or pass `--profiles-dir .`.

## Architecture

- **Stack**: dbt-duckdb (dbt-core 1.9.10) against a local DuckDB file at `./data/warehouse.duckdb`. Profile `highcore_ae_test`, single `dev` target. See `profiles.yml` and `requirements.txt`.
- **Source**: `raw.events` — Firebase Analytics export covering 2018-06-12 → 2018-10-03 (`models/staging/_sources.yml`). Populated by `scripts/prepare_data.py`.
- **Layer materializations** come from `dbt_project.yml`: `staging/` and `intermediate/` are views, `marts/` are tables. Override with `{{ config(materialized=...) }}` only when justified, and note why.
- Layers are scaffolded but empty except for the example `models/staging/stg_events.sql`. Expected flow: `staging` → `intermediate` → `marts` feeding the dashboard mart(s).

## Working with the raw event schema

The non-obvious DuckDB / Firebase patterns (see `models/staging/stg_events.sql` for a working example):

- **Timestamps**: `event_timestamp` is **microseconds since epoch**. Wrap in `make_timestamp(event_timestamp)` to get a `TIMESTAMP`. `event_date` is already a date.
- **Unnesting `event_params` / `user_properties`** (lists of `{key, value}` structs):
  ```sql
  (list_filter(event_params, x -> x.key = 'ga_session_id')[1]).value.int_value
  ```
  Pick the right `*_value` field — one of `string_value`, `int_value`, `double_value`, `float_value` — for the parameter you want.
- **Struct fields** `device`, `geo`, `app_info`, `traffic_source` use dot access: `device.category`, `geo.country`, etc.
- **Identifiers**: `user_pseudo_id` is always present and is the right join key for cohorting. `user_id` is only set when the app calls `setUserId` and is frequently null — don't use it as the cohort key.
- This dataset is the BQ public table `firebase-public-project.analytics_153293282`. The DuckDB dialect is close but not identical to BigQuery — prefer DuckDB list/struct functions over BQ `UNNEST` syntax.

## Data download caveat

`scripts/prepare_data.py` pulls ~500 MB from a public Google Drive link via `gdown`. If Drive throttles, the README documents a manual fallback: drop the file at `data/firebase_events.parquet` and re-run `make setup`. The script no-ops the download if the parquet already exists, so re-running is safe.

## Deliverable layout

`models/{staging,intermediate,marts}/`, `macros/`, `tests/`, `docs/`, and `skills/` exist with `.gitkeep` placeholders. New work goes into those directories. The custom skill needs its own folder with a `SKILL.md` (e.g. `skills/<skill-name>/SKILL.md`).

## Workflow

- Create a separate branch for each task (`feature/...`, `fix/...`)
- Make atomic commits with meaningful messages as you go
- Review your own code after writing it, before committing/opening a PR
- Verify the code by running it (tests, linter, or manual execution) before considering the task done
- Document changes: update README, docstrings, and comments on public APIs

## YAML — источник доков, SQL — код. Кросс-ссылок между ними не пишем
  - В YAML (`_models.yml`, `_sources.yml`, `_unit_tests.yml`, `_tests.yml`, `_macros.yml`) свободный текст описаний / EDGE CASES / meta не ссылается на `docs/*.md`. YAML рендерится в `dbt docs`; внешняя `.md`-ссылка там некликабельна и неинформативна. Нужен контекст — инлайн одной фразой.
  - В SQL-файлах (`models/**/*.sql`, `tests/*.sql`, `macros/*.sql`) заголовочный стуб вида `-- See tests/_tests.yml for full docs` — шум: файлы парные по имени, doc-блок найдут и так.
  - Исключение: doc-blocks через нативную dbt-механику (`{% docs name %} … {% enddocs %}` файлы и `doc('name')` в YAML) — это легитимный реюз внутри dbt.

## SQL-header в моделях — только implementation rationale

SQL-header (top-of-file `{#- ... -#}` блок) допустим только для DuckDB-/dialect-specific implementation rationale, которого нет в YAML. Семантика (роль, грейн, EDGE CASES) — в `_models.yml`. Drift-чек: «если убрать header, теряется ли что-то про *как именно работает SQL*?» Если нет — header удаляется. Текущий рабочий пример — `models/staging/stg_events.sql:7-19` (DuckDB-only materialization override + int64-max sentinel в dedup tie-break).