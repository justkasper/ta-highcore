{{
    config(
        materialized='table',
        post_hook="ANALYZE {{ this }}"
    )
}}

{#-
    Materialization override (view → table) is local to DuckDB: under
    default test concurrency every downstream view re-scans the 5.7M-row
    source and `dbt test` OOM'd. Persisting once collapses subsequent
    scans to milliseconds.

    Dedup tie-break uses an int64-max sentinel via `coalesce(...,
    9223372036854775807)` instead of `NULLS LAST`: DuckDB's `list`
    aggregate ORDER BY does not expose `NULLS LAST` inside a list
    aggregate, so NULL-tolerant ordering needs an explicit sentinel.
-#}

with raw_events as (
    select rowid as _src_rowid, *
    from {{ source('raw', 'events') }}
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

        event_value_in_usd::numeric(18, 4) as event_value_in_usd,
        event_previous_timestamp,
        event_bundle_sequence_id,
        event_server_timestamp_offset,

        (list_filter(event_params, x -> x.key = 'engagement_time_msec')[1]).value.int_value
            as engagement_time_msec,
        (list_filter(event_params, x -> x.key = 'firebase_screen_class')[1]).value.string_value
            as screen_class,
        (list_filter(event_params, x -> x.key = 'previous_first_open_count')[1]).value.int_value
            as previous_first_open_count,
        (list_filter(event_params, x -> x.key = 'ga_session_id')[1]).value.int_value
            as ga_session_id,

        device.category as device_category,
        nullif(device.operating_system, 'NaN') as device_os,
        geo.country as country,
        app_info.id as app_id,
        traffic_source.medium as traffic_medium,
        traffic_source.name as traffic_source_name

    from deduped
)

select * from typed
