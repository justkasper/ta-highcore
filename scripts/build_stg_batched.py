"""
Memory-bounded `stg_events` builder for sandboxes that can't fit the
full DuckDB CTAS in 8 GB RAM.

The model `models/staging/stg_events.sql` runs as a single
CREATE TABLE AS SELECT over 5.7M rows × fat structs. Even with
spill, transient buffers can exceed the OS OOM ceiling on a 2-core
/ 8 GB sandbox; see README §"Локальные ограничения".

This script reproduces the same logical output by partitioning the
work over `event_date` (114 days × ~50K rows). Dedup is correct
per-day because the dedup key `(user_pseudo_id, event_timestamp,
event_name)` cannot collide across calendar days — `event_timestamp`
is microsecond-precision UTC.

Usage:
    python scripts/build_stg_batched.py         # bootstrap + 113 inserts
    python scripts/build_stg_batched.py --check # dry-run, print plan only

Run it BEFORE `dbt build`. Then `dbt build --exclude stg_events`
materializes the rest of the pipeline.

NOT for production. On BigQuery the model SQL runs as-is — this
workaround is local-DuckDB only.
"""

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

import duckdb

REPO_ROOT = Path(__file__).resolve().parent.parent
DB_PATH = REPO_ROOT / "data" / "warehouse.duckdb"

# Schema this script is expected to write. If models/staging/stg_events.sql
# adds, removes, or renames a column, update INSERT_TEMPLATE AND this tuple
# in lock-step — the bootstrap will refuse to proceed if they drift apart.
EXPECTED_COLUMNS = (
    "event_date", "event_timestamp", "event_ts_utc", "event_date_utc",
    "event_name", "user_pseudo_id", "platform",
    "event_value_in_usd", "event_previous_timestamp",
    "event_bundle_sequence_id", "event_server_timestamp_offset",
    "engagement_time_msec", "screen_class", "previous_first_open_count",
    "ga_session_id", "device_category", "device_os", "country",
    "app_id", "traffic_medium", "traffic_source_name",
)

# Mirrors the typed projection from models/staging/stg_events.sql.
# Kept in sync manually — when the model SQL changes, update this template.
INSERT_TEMPLATE = """
with raw_events as (
    select rowid as _src_rowid, *
    from raw.events
    where event_date = ?
),
dedup_keys as (
    select
        _src_rowid,
        user_pseudo_id,
        event_timestamp,
        event_name,
        event_bundle_sequence_id,
        event_server_timestamp_offset
    from raw_events
),
losing_dupe_rowids as (
    select unnest(
        list(_src_rowid order by
            coalesce(event_bundle_sequence_id, 9223372036854775807),
            coalesce(event_server_timestamp_offset, 9223372036854775807)
        )[2:]
    ) as _src_rowid
    from dedup_keys
    group by user_pseudo_id, event_timestamp, event_name
    having count(*) > 1
),
deduped as (
    select * from raw_events
    where _src_rowid not in (select _src_rowid from losing_dupe_rowids)
)
select
    event_date,
    event_timestamp,
    make_timestamp(event_timestamp) as event_ts_utc,
    make_timestamp(event_timestamp)::date as event_date_utc,
    event_name,
    user_pseudo_id,
    platform,
    event_value_in_usd,
    event_previous_timestamp,
    event_bundle_sequence_id,
    event_server_timestamp_offset,
    (list_filter(event_params, x -> x.key = 'engagement_time_msec')[1]).value.int_value as engagement_time_msec,
    (list_filter(event_params, x -> x.key = 'firebase_screen_class')[1]).value.string_value as screen_class,
    (list_filter(event_params, x -> x.key = 'previous_first_open_count')[1]).value.int_value as previous_first_open_count,
    (list_filter(event_params, x -> x.key = 'ga_session_id')[1]).value.int_value as ga_session_id,
    device.category as device_category,
    nullif(device.operating_system, 'NaN') as device_os,
    geo.country as country,
    app_info.id as app_id,
    traffic_source.medium as traffic_medium,
    traffic_source.name as traffic_source_name
from deduped
"""

DUCKDB_SETTINGS = [
    "SET memory_limit='2GB'",
    "SET threads=1",
    "SET preserve_insertion_order=false",
    "SET temp_directory='./data/warehouse.duckdb.tmp'",
]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument(
        "--check",
        action="store_true",
        help="Print the plan (date list + chunk count) without writing.",
    )
    args = parser.parse_args()

    if not DB_PATH.exists():
        sys.stderr.write(f"warehouse not found at {DB_PATH}\n")
        sys.stderr.write("run `make setup` first to populate raw.events\n")
        return 1

    con = duckdb.connect(str(DB_PATH))
    for stmt in DUCKDB_SETTINGS:
        con.execute(stmt)

    dates = [
        row[0]
        for row in con.execute(
            "select distinct event_date from raw.events order by 1"
        ).fetchall()
    ]
    print(f"raw.events covers {len(dates)} distinct event_date values")
    print(f"first: {dates[0]}    last: {dates[-1]}")

    if args.check:
        return 0

    con.execute("DROP TABLE IF EXISTS main.stg_events")

    bootstrap_date, *rest = dates
    t0 = time.monotonic()

    print(f"[1/{len(dates)}] bootstrap from {bootstrap_date} ...")
    con.execute(
        f"CREATE TABLE main.stg_events AS {INSERT_TEMPLATE}",
        [bootstrap_date],
    )

    actual_columns = tuple(
        row[0] for row in con.execute("DESCRIBE main.stg_events").fetchall()
    )
    if actual_columns != EXPECTED_COLUMNS:
        sys.stderr.write(
            "stg_events schema drift detected after bootstrap.\n"
            f"  expected: {EXPECTED_COLUMNS}\n"
            f"  got:      {actual_columns}\n"
            "Update INSERT_TEMPLATE and EXPECTED_COLUMNS in this file to\n"
            "match models/staging/stg_events.sql, then re-run.\n"
        )
        return 1

    for i, d in enumerate(rest, start=2):
        print(f"[{i}/{len(dates)}] insert {d} ...")
        con.execute(
            f"INSERT INTO main.stg_events {INSERT_TEMPLATE}",
            [d],
        )

    elapsed = time.monotonic() - t0
    rows = con.execute("select count(*) from main.stg_events").fetchone()[0]
    print(f"\nDone. {rows:,} rows in main.stg_events ({elapsed:.1f}s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
