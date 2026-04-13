with source as (
    select * from {{ source('raw', 'events') }}
),

base as (
    select
        event_date,
        -- event_timestamp is in microseconds since epoch
        make_timestamp(event_timestamp) as event_timestamp,
        event_name,
        user_pseudo_id,
        user_id,
        platform,

       
        (list_filter(event_params, x -> x.key = 'ga_session_id')[1]).value.int_value as ga_session_id,
        (list_filter(event_params, x -> x.key = 'engagement_time_msec')[1]).value.int_value as engagement_time_msec,
        (list_filter(event_params, x -> x.key = 'firebase_screen_class')[1]).value.string_value as screen_class,

        
        event_params,
        user_properties,
        device,
        geo,
        app_info,
        traffic_source

    from source
)

select * from base
