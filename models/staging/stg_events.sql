{{
    config(
        materialized='table',
        post_hook="ANALYZE {{ this }}"
    )
}}

{#-
    Materialization override (view → table) is local to DuckDB: every
    downstream view re-scans the 5.7M-row source on each test run, which
    pushed `dbt test` into OOM under default concurrency. Persisting once
    turns subsequent scans into milliseconds. The BQ-target config and
    user-facing semantics live in `_models.yml`.

    Dedup uses a hash aggregate that emits only losing rowids
    (`list(_src_rowid order by …)[2:]` after `having count(*) > 1`),
    followed by an anti-join. `qualify row_number()` over the 5.7M-row
    partition spilled past 8 GB on cold rebuild even on a thin key
    projection. The aggregate has no global sort; per-group list-sort is
    free because HAVING discards the ~99% groups of size 1, leaving only
    a few thousand dupe groups, so the anti-join's build side is tiny.
-#}

with raw_events as (
    select rowid as _src_rowid, *
    from {{ source('raw', 'events') }}
),

dedup_keys as (
    -- thin projection so the aggregate scan is column-pruned at the parquet/
    -- DuckDB reader and never holds the fat structs (event_params,
    -- user_properties, device, geo, …) in memory.
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
    -- For each (user_pseudo_id, event_timestamp, event_name) group with
    -- >1 rows, list rowids ordered by the same tie-break the original
    -- window used (event_bundle_sequence_id NULLS LAST, then
    -- event_server_timestamp_offset NULLS LAST — emulated via int64-max
    -- sentinel because struct/list ORDER BY does not expose NULLS LAST
    -- inside a list aggregate). Slice [2:] drops the canonical winner
    -- and emits only the losers via UNNEST.
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
    select *
    from raw_events
    where _src_rowid not in (select _src_rowid from losing_dupe_rowids)
),

typed as (
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

        -- event_params extractions: only keys downstream models actually use
        (list_filter(event_params, x -> x.key = 'engagement_time_msec')[1]).value.int_value
            as engagement_time_msec,
        (list_filter(event_params, x -> x.key = 'firebase_screen_class')[1]).value.string_value
            as screen_class,
        (list_filter(event_params, x -> x.key = 'previous_first_open_count')[1]).value.int_value
            as previous_first_open_count,
        (list_filter(event_params, x -> x.key = 'ga_session_id')[1]).value.int_value
            as ga_session_id,

        -- struct → top-level
        device.category                              as device_category,
        nullif(device.operating_system, 'NaN')       as device_os,
        geo.country                                  as country,
        app_info.id                                  as app_id,
        traffic_source.medium                        as traffic_medium,
        traffic_source.name                          as traffic_source_name

    from deduped
)

select * from typed
