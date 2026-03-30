{{
    config(
        materialized='table',
        schema='snowflake_schema'
    )
}}

/*
    SNOWFLAKE SCHEMA: Time Dimension

    In Star Schema: time attributes are computed inline (hour_of_day, is_weekend, etc.)
    In Snowflake Schema: they get their own dimension table.

    This is a date spine — one row per hour for a defined range.
    Fact tables JOIN to this on reading_hour instead of computing time fields per row.

    Industry standard: almost every data warehouse has a date/time dimension.
    Pre-computing is_holiday, fiscal_quarter, etc. is much cleaner than inline CASE.
*/

with hours as (
    select
        dateadd(hour, seq4(), '2025-01-01'::timestamp) as hour_ts
    from table(generator(rowcount => 24 * 365 * 2))  -- 2 years of hours
),

time_dim as (
    select
        hour_ts,
        date_trunc('day', hour_ts) as date_day,
        date_trunc('week', hour_ts) as date_week,
        date_trunc('month', hour_ts) as date_month,
        date_trunc('quarter', hour_ts) as date_quarter,
        extract(year from hour_ts) as year,
        extract(month from hour_ts) as month,
        extract(day from hour_ts) as day_of_month,
        extract(hour from hour_ts) as hour_of_day,
        dayname(hour_ts) as day_name,
        dayofweek(hour_ts) as day_of_week_num,
        case when dayofweek(hour_ts) in (0, 6) then true else false end as is_weekend,
        case when extract(hour from hour_ts) between 8 and 17 then true else false end as is_business_hours,
        case when extract(hour from hour_ts) between 6 and 9 then 'morning'
             when extract(hour from hour_ts) between 10 and 13 then 'midday'
             when extract(hour from hour_ts) between 14 and 17 then 'afternoon'
             when extract(hour from hour_ts) between 18 and 21 then 'evening'
             else 'night'
        end as time_of_day_category
    from hours
)

select
    {{ dbt_utils.generate_surrogate_key(['hour_ts']) }} as time_sk,
    *
from time_dim
