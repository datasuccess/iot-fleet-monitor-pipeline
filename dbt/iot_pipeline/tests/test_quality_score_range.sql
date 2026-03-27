/*
    Quality scores must be between 0 and 100.
*/

select
    quality_id,
    source_file,
    quality_score
from {{ ref('fct_data_quality') }}
where quality_score < 0 or quality_score > 100
