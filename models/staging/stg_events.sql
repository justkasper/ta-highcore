{{
    config(
        materialized='table',
        post_hook="ANALYZE {{ this }}"
    )
}}

{#-
    Materialization override (view → table) is local to DuckDB. Rationale:
    every downstream view re-scans the 5.7M-row source on every test run,
    which made `dbt test` push DuckDB into OOM under default 4-thread
    concurrency. Persisting the cleaned event stream once turns subsequent
    test queries into millisecond-level scans.

    On BigQuery this becomes
    `materialized=incremental, partition_by=event_date_utc,
     unique_key=(user_pseudo_id, event_timestamp, event_name),
     incremental_strategy='merge'` — the SQL stays the same.

    Dedup is implemented in two phases (rowid + anti-join on losing duplicates)
    rather than a single `qualify` over the full projection. The full row is
    fat (event_params LIST<STRUCT>, user_properties LIST<STRUCT>, device STRUCT,
    geo STRUCT, …); pushing all of that through a window operator is what
    triggered OOM on 8 GB local DuckDB. The thin-key window fits comfortably,
    and the dedup logic is identical.
-#}

with source as (
    select rowid as _src_rowid, *
    from {{ source('raw', 'events') }}
),

losing_dupe_rowids as (
    select _src_rowid
    from source
    qualify row_number() over (
        partition by user_pseudo_id, event_timestamp, event_name
        order by event_bundle_sequence_id nulls last,
                 event_server_timestamp_offset nulls last
    ) > 1
),

deduped as (
    select *
    from source
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
